# frozen_string_literal: true

module HireFire
  module Macro
    module Delayed
      module Job
        extend HireFire::Errors::QueueMethodRenamed
        extend HireFire::Errors::LatencyMethodRenamed
        extend self

        class MapperNotDetectedError < StandardError; end

        # Calculates the maximum job queue latency across the specified queues.
        # Both ActiveRecord and Mongoid are supported.
        #
        # @param queues [Array<String, Symbol>] provide one or more queue names.
        # @param priority [Integer, Range, nil] specific priority or a range of priorities.
        # @return [Integer] Maximum latency in seconds across the specified queues.
        # @raise [HireFire::Errors::MissingQueueError] Raised when no queue names are provided.
        # @example Job Queue Latency of the default queue
        #   HireFire::Macro::Delayed::Job.job_queue_latency(:default)
        # @example Maximum Job Queue Latency across the default and mailer queues
        #   HireFire::Macro::Delayed::Job.job_queue_latency(:default, :mailer)
        # @example Job Queue Latency of jobs with priority 5 in the default queue
        #   HireFire::Macro::Delayed::Job.job_queue_latency(:default, priority: 5)
        def job_queue_latency(*queues, priority: nil)
          queues = Utility.construct_queues(queues)

          query = ::Delayed::Job
          query = query.where(priority: priority) if priority
          query = query.where(run_at: ..Time.now)
          query = query.where(failed_at: nil)
          query = query.order(priority: :asc, run_at: :asc)

          case mapper
          when :active_record
            query = query.where(queue: queues) if queues.any?
          when :mongoid
            query = query.in(queue: queues.to_a) if queues.any?
          end

          if (job = query.first)
            (Time.now - job.run_at).round
          else
            0
          end
        end

        # Calculates the total job queue size across the specified queues.
        # Both ActiveRecord and Mongoid are supported.
        #
        # @param queues [Array<String, Symbol>] provide one or more queue names.
        # @param priority [Integer, Range, nil] specific priority or a range of priorities.
        # @return [Integer] Cumulative queue size across the specified queues.
        # @raise [HireFire::Errors::MissingQueueError] Raised when no queue names are provided.
        # @example Job Queue Size of the default queue
        #   HireFire::Macro::Delayed::Job.job_queue_size(:default)
        # @example Job Queue Size across the "default" and "mailer" queues
        #   HireFire::Macro::Delayed::Job.job_queue_size(:default, :mailer)
        # @example Job Queue Size with priority 5 jobs in the default queue
        #   HireFire::Macro::Delayed::Job.job_queue_size(:default, priority: 5)
        # @example Job Queue Size with priority 3 to 7 jobs in the default queue
        #   HireFire::Macro::Delayed::Job.job_queue_size(:default, priority: 3..7)
        def job_queue_size(*queues, priority: nil)
          queues = Utility.construct_queues(queues)

          query = ::Delayed::Job
          query = query.where(priority: priority) if priority
          query = query.where(run_at: ..Time.now)
          query = query.where(failed_at: nil)

          case mapper
          when :active_record
            query = query.where(queue: queues) if queues.any?
          when :mongoid
            query = query.in(queue: queues.to_a) if queues.any?
          end

          query.count
        end

        private

        # Detects and returns the mapper currently in use.
        # The mapper can be either :active_record or :mongoid.
        #
        # @return [Symbol] the detected mapper (:active_record or :mongoid).
        # @raise [MapperNotDetectedError] if unable to detect the appropriate mapper.
        def mapper
          return :active_record if defined?(::ActiveRecord::Base) &&
            ::Delayed::Job.ancestors.include?(::ActiveRecord::Base)

          return :mongoid if defined?(::Mongoid::Document) &&
            ::Delayed::Job.ancestors.include?(::Mongoid::Document)

          raise MapperNotDetectedError, "Unable to detect the appropriate mapper."
        end
      end
    end
  end
end
