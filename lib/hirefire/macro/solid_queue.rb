# frozen_string_literal: true

require_relative "helpers/active_record_connection"
require_relative "../plan/hooks"
require_relative "../utility"

module HireFire
  module Macro
    module SolidQueue
      extend HireFire::Macro::Utility
      extend HireFire::Macro::Helpers::ActiveRecordConnection
      extend HireFire::Plan::Hooks
      extend self

      REGISTERED_QUEUE_TTL = 60.0

      PLAN_OPTION_SCHEMA = {
        Strategy::JQS => {
          "skip_working" => :boolean
        }.freeze
      }.freeze

      def library_loaded?
        !!defined?(::SolidQueue)
      end

      def plan_options(strategy, options)
        extract_plan_options(strategy, options, PLAN_OPTION_SCHEMA)
      end

      def job_queue_latency(*queues)
        with_connection(::SolidQueue::Record) do
          queues, now = determine_queues(queues), Time.now

          [ready_latency(queues, now: now), scheduled_latency(queues, now: now)].max
        end
      end

      def job_queue_size(*queues, skip_working: false)
        with_connection(::SolidQueue::Record) do
          queues = determine_queues(queues)
          size = ready_size(queues) + scheduled_size(queues)

          skip_working ? size : size + claimed_size(queues)
        end
      end

      def job_queue_working(*queues)
        with_connection(::SolidQueue::Record) do
          queues = determine_queues(queues)
          claimed_size(queues)
        end
      end

      def before_sample_job_queues
        @round = true
        @round_paused_queues = nil
      end

      def after_sample_job_queues(_token = nil)
        @round = false
      end

      def reinit_after_fork
        after_sample_job_queues
        @registered_queues_at = nil
      end

      private

      def determine_queues(queues)
        queues = normalize_queues(queues, allow_empty: true)

        Set.new(queues.empty? ? registered_queues : expand_wildcards(queues)) - paused_queues
      end

      def paused_queues
        return ::SolidQueue::Pause.pluck(:queue_name) unless @round

        @round_paused_queues ||= ::SolidQueue::Pause.pluck(:queue_name)
      end

      def registered_queues
        now = Clock.monotonic
        return @registered_queues if @registered_queues_at && (now - @registered_queues_at) < REGISTERED_QUEUE_TTL

        @registered_queues_at = now
        @registered_queues = ::SolidQueue::Queue.all.map(&:name)
      end

      def expand_wildcards(queues)
        queues.flat_map do |queue|
          queue.end_with?("*") ? registered_queues.select { |name| name.start_with?(queue[0..-2]) } : queue
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
