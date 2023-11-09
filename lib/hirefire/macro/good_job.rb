# frozen_string_literal: true

module HireFire
  module Macro
    module GoodJob
      extend HireFire::Errors::QueueMethodRenamed
      extend HireFire::Errors::LatencyMethodRenamed
      extend self

      # Calculates the maximum job queue latency across the specified queues.
      #
      # @param queues [Array<String, Symbol>] the list of queues to check latency for.
      # @param priority [Integer, Range, nil] optional priority filter.
      # @return [Integer] Maximum job queue latency in seconds across the specified queues.
      # @raise [HireFire::Errors::MissingQueueError] Raised when no queue names are provided.
      # @example Job Queue Latency for the default queue
      #   HireFire::Macro::GoodJob.job_queue_latency(:default)
      # @example Maximum Job Queue Latency across the default and mailer queues
      #   HireFire::Macro::GoodJob.job_queue_latency(:default, :mailer)
      # @example Job Queue Latency for the default queue, scoped by priority 3 jobs
      #   HireFire::Macro::GoodJob.job_queue_latency(:default, priority: 3)
      # @example Job Queue Latency of the default queue, scoped by priority 3 to 7 jobs
      #   HireFire::Macro::GoodJob.job_queue_latency(:default, priority: 3..7)
      def job_queue_latency(*queues, priority: nil)
        queues = Utility.construct_queues(queues)

        query = ::GoodJob::Execution
        query = query.where(queue_name: queues)
        query = query.where(finished_at: nil)
        query = query.where(scheduled_at: ..Time.now).or(query.where(scheduled_at: nil))
        query = query.where(priority: priority) if priority
        query = query.order(priority: priority_order, scheduled_at: :asc, created_at: :asc)

        if (job = query.first)
          (Time.now - (job.scheduled_at || job.created_at)).round
        else
          0
        end
      end

      # Calculates the total job queue size across the specified queues.
      #
      # @param queues [Array<String, Symbol>] the list of queues to count.
      # @param priority [Integer, Range, nil] optional priority filter.
      # @return [Integer] Cumulative job queue size across the specified queues.
      # @raise [HireFire::Errors::MissingQueueError] Raised when no queue names are provided.
      # @example Job Queue Size for the default queue
      #   HireFire::Macro::GoodJob.job_queue_size(:default)
      # @example Job Queue Size across the default and mailer queues
      #   HireFire::Macro::GoodJob.job_queue_size(:default, :mailer)
      # @example Job Queue Size for the default queue, scoped by priority 3 jobs
      #   HireFire::Macro::GoodJob.job_queue_size(:default, priority: 3)
      # @example Job Queue Size for the default queue, scoped by priority 3 to 7 jobs
      #   HireFire::Macro::GoodJob.job_queue_size(:default, priority: 3..7)
      def job_queue_size(*queues, priority: nil)
        queues = Utility.construct_queues(queues)

        query = ::GoodJob::Execution
        query = query.where(queue_name: queues)
        query = query.where(finished_at: nil)
        query = query.where(scheduled_at: ..Time.now).or(query.where(scheduled_at: nil))
        query = query.where(priority: priority) if priority

        query.count
      end

      private

      # Determine the priority order based on GoodJob's version or configuration.
      #
      # @return [Symbol] either :asc or :desc.
      def priority_order
        if Gem::Version.new(::GoodJob::VERSION) >= Gem::Version.new("4.0.0")
          :asc
        elsif Rails.application.config.try(:good_job).try(:smaller_number_is_higher_priority)
          :asc
        else
          :desc
        end
      end
    end
  end
end
