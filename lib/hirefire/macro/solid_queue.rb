# frozen_string_literal: true

module HireFire
  module Macro
    module SolidQueue
      extend HireFire::Utility
      extend self

      LATENCY_METHODS = [
        :ready_latency,
        :scheduled_latency,
        :blocked_latency
      ].freeze

      # Calculates the maximum job queue latency using SolidQueue. If no queues are specified, it
      # measures latency across all available queues.
      #
      # This function measures the job queue latency across the Ready, Scheduled, and Blocked
      # queues, based on the enqueue, schedule, and expiration times of their executions. Executions
      # in the Claimed queue, as well as in paused queues, are excluded from the calculation.
      #
      # @param queues [Array<String, Symbol>] (optional) Names of the queues for latency
      #   measurement. If not provided, latency is measured across all queues.
      # @return [Float] Maximum job queue latency in seconds.
      # @example Calculate latency across all queues
      #   HireFire::Macro::SolidQueue.job_queue_latency
      # @example Calculate latency for the "default" queue
      #   HireFire::Macro::SolidQueue.job_queue_latency(:default)
      # @example Calculate latency across "default" and "mailer" queues
      #   HireFire::Macro::SolidQueue.job_queue_latency(:default, :mailer)
      # @example Calculate latency across "mailer_*" queues (i.e. mailer_notification, mailer_newsletter)
      #   HireFire::Macro::SolidQueue.job_queue_latency(:"mailer_*")
      def job_queue_latency(*queues)
        queues, now = determine_queues(queues), Time.now

        LATENCY_METHODS.map do |latency_method|
          method(latency_method).call(queues, now: now)
        end.max
      end

      SIZE_METHODS = [
        :ready_size,
        :scheduled_size,
        :claimed_size,
        :blocked_size
      ].freeze

      # Calculates the total job queue size using SolidQueue. If no queues are specified, it
      # measures size across all available queues.
      #
      # This function measures the job queue latency across the Ready, Scheduled, Blocked, and
      # Claimed queues, based on the schedule and expiration times of their executions. Executions
      # in paused queues are excluded from the calculation.
      #
      # @param queues [Array<String, Symbol>] (optional) Names of the queues for size measurement.
      #   If not provided, size is measured across all queues.
      # @return [Integer] Total job queue size.
      # @example Calculate size across all queues
      #   HireFire::Macro::SolidQueue.job_queue_size
      # @example Calculate size for the "default" queue
      #   HireFire::Macro::SolidQueue.job_queue_size(:default)
      # @example Calculate size across "default" and "mailer" queues
      #   HireFire::Macro::SolidQueue.job_queue_size(:default, :mailer)
      # @example Calculate size across "mailer_*" queues (i.e. mailer_notification, mailer_newsletter)
      #   HireFire::Macro::SolidQueue.job_queue_size(:"mailer_*")
      def job_queue_size(*queues)
        queues = determine_queues(queues)

        SIZE_METHODS.sum do |count_method|
          method(count_method).call(queues)
        end
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
        ::SolidQueue::Queue.all.map(&:name)
      end

      def paused_queues
        ::SolidQueue::Pause.pluck(:queue_name)
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
        now - (
          ::SolidQueue::ReadyExecution
            .where(queue_name: queues)
            .minimum(:created_at) || now
        )
      end

      def ready_size(queues)
        ::SolidQueue::ReadyExecution
          .where(queue_name: queues)
          .count
      end

      def scheduled_latency(queues, now:)
        now - (
          ::SolidQueue::ScheduledExecution
            .due
            .where(queue_name: queues)
            .minimum(:scheduled_at) || now
        )
      end

      def scheduled_size(queues)
        ::SolidQueue::ScheduledExecution
          .due
          .where(queue_name: queues)
          .count
      end

      def blocked_latency(queues, now:)
        now - (
          ::SolidQueue::BlockedExecution
            .expired
            .where(queue_name: queues)
            .minimum(:expires_at) || now
        )
      end

      def blocked_size(queues)
        ::SolidQueue::BlockedExecution
          .expired
          .where(queue_name: queues)
          .count
      end

      def claimed_size(queues)
        ::SolidQueue::Job
          .joins(:claimed_execution)
          .where(queue_name: queues)
          .count
      end
    end
  end
end
