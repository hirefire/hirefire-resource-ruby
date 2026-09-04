# frozen_string_literal: true

require_relative "helpers/active_record_connection"
require_relative "../plan/hooks"

module HireFire
  module Macro
    module SolidQueue
      extend HireFire::Macro::Utility
      extend HireFire::Macro::Helpers::ActiveRecordConnection
      extend HireFire::Plan::Hooks
      extend self

      REGISTERED_QUEUE_TTL = 60.0

      LATENCY_METHODS = [
        :ready_latency,
        :scheduled_latency
      ].freeze

      def job_queue_latency(*queues)
        with_connection do
          queues, now = determine_queues(queues), Time.now

          LATENCY_METHODS.map do |latency_method|
            method(latency_method).call(queues, now: now)
          end.max
        end
      end

      SIZE_METHODS = [
        :ready_size,
        :scheduled_size
      ].freeze

      def job_queue_size(*queues)
        with_connection do
          queues = determine_queues(queues)

          SIZE_METHODS.sum do |count_method|
            method(count_method).call(queues)
          end
        end
      end

      def job_queue_working(*queues)
        with_connection do
          queues = determine_queues(queues)
          claimed_size(queues)
        end
      end

      def before_sample_job_queues
        return nil unless defined?(::SolidQueue)

        @wave_registered_queues = :pending
        @wave_paused_queues = :pending
        true
      end

      def after_sample_job_queues(_token = nil)
        @wave_registered_queues = nil
        @wave_paused_queues = nil
      end

      def reinit_after_fork
        @wave_registered_queues = nil
        @wave_paused_queues = nil
        @registered_queue_cache = nil
        @registered_queue_cache_at = nil
      end

      private

      def determine_queues(queues)
        queues = normalize_queues(queues, allow_empty: true)

        Set.new(
          if queues.empty?
            registered_queues
          elsif queues.any? { |queue| queue.end_with?("*") }
            expand_wildcards(queues)
          else
            queues
          end
        ) - paused_queues
      end

      def registered_queues
        prefetch_wave_lists
        @wave_registered_queues || cached_registered_queue_names
      end

      def paused_queues
        prefetch_wave_lists
        @wave_paused_queues || ::SolidQueue::Pause.pluck(:queue_name)
      end

      def prefetch_wave_lists
        return unless @wave_registered_queues == :pending

        with_connection do
          @wave_registered_queues = cached_registered_queue_names
          @wave_paused_queues = ::SolidQueue::Pause.pluck(:queue_name)
        end
      end

      def cached_registered_queue_names
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        names = @registered_queue_cache
        cached_at = @registered_queue_cache_at
        if names && cached_at && (now - cached_at) < REGISTERED_QUEUE_TTL
          return names
        end

        names = ::SolidQueue::Queue.all.map(&:name)
        @registered_queue_cache = names
        @registered_queue_cache_at = now
        names
      end

      def expand_wildcards(queues)
        cached_registered_queues = registered_queues

        queues.flat_map do |queue|
          if queue.end_with?("*")
            cached_registered_queues.select do |registered_queue|
              registered_queue.start_with?(queue[0..-2])
            end
          else
            queue
          end
        end
      end

      def ready_latency(queues, now:)
        [
          now - (
            ::SolidQueue::ReadyExecution
              .where(queue_name: queues)
              .minimum(:created_at) || now
          ),
          0.0
        ].max
      end

      def ready_size(queues)
        ::SolidQueue::ReadyExecution
          .where(queue_name: queues)
          .count
      end

      def scheduled_latency(queues, now:)
        [
          now - (
            ::SolidQueue::ScheduledExecution
              .due
              .where(queue_name: queues)
              .minimum(:scheduled_at) || now
          ),
          0.0
        ].max
      end

      def scheduled_size(queues)
        ::SolidQueue::ScheduledExecution
          .due
          .where(queue_name: queues)
          .count
      end

      def claimed_size(queues)
        ::SolidQueue::ClaimedExecution
          .joins(:job)
          .where(solid_queue_jobs: {queue_name: queues})
          .count
      end
    end
  end
end
