# frozen_string_literal: true

require_relative "helpers/active_record_connection"
require_relative "../plan/hooks"
require_relative "deprecated/delayed_job"

module HireFire
  module Macro
    module Delayed
      module Job
        extend HireFire::Macro::Deprecated::Delayed::Job
        extend HireFire::Utility
        extend HireFire::Macro::Helpers::ActiveRecordConnection
        extend HireFire::Plan::Hooks
        extend self

        # Raised when neither Active Record nor Mongoid can be detected as the Delayed::Job
        # persistence backend.
        class MapperNotDetectedError < StandardError; end

        # Calculates the maximum job queue latency using Delayed::Job. If no queues are specified,
        # it measures latency across all available queues. This method supports both ActiveRecord
        # and Mongoid mappers.
        #
        # Waiting set only: due jobs (`failed_at` null, `run_at` ≤ now) that are unlocked
        # (`locked_at` null). Locked (working) jobs are excluded. Future `run_at` is not measured.
        #
        # @param queues [Array<String, Symbol>] (optional) Names of the queues for latency
        #   measurement. If not provided, latency is measured across all queues.
        # @return [Float] Maximum job queue latency in seconds.
        # @raise [HireFire::Macro::Delayed::Job::MapperNotDetectedError] if neither an ActiveRecord
        #   nor a Mongoid mapper can be detected.
        # @example Calculate latency across all queues
        #   HireFire::Macro::Delayed::Job.job_queue_latency
        # @example Calculate latency for the "default" queue
        #   HireFire::Macro::Delayed::Job.job_queue_latency(:default)
        # @example Calculate latency across "default" and "mailer" queues
        #   HireFire::Macro::Delayed::Job.job_queue_latency(:default, :mailer)
        def job_queue_latency(*queues)
          with_connection do
            queues = normalize_queues(queues, allow_empty: true)
            query = waiting_scope.order(run_at: :asc)

            case mapper
            when :active_record
              query = query.where("run_at <= ?", Time.now)
              query = query.where(queue: queues) if queues.any?
            when :mongoid
              query = query.where(run_at: {"$lte" => Time.now})
              query = query.in(queue: queues.to_a) if queues.any?
            end

            if (job = query.first)
              Time.now - job.run_at
            else
              0.0
            end
          end
        end

        # Calculates the total job queue size using Delayed::Job. If no queues are specified, it
        # measures size across all available queues. This method supports both ActiveRecord and
        # Mongoid mappers.
        #
        # Waiting set only: due jobs (`failed_at` null, `run_at` ≤ now) that are unlocked
        # (`locked_at` null). Locked (working) jobs are excluded. Future `run_at` is not counted.
        #
        # @param queues [Array<String, Symbol>] (optional) Names of the queues for size measurement.
        #   If not provided, size is measured across all queues.
        # @return [Integer] Total job queue size (waiting set: due + unlocked).
        # @raise [HireFire::Macro::Delayed::Job::MapperNotDetectedError] if neither an ActiveRecord
        #   nor a Mongoid mapper can be detected.
        # @example Calculate size across all queues
        #   HireFire::Macro::Delayed::Job.job_queue_size
        # @example Calculate size of the "default" queue
        #   HireFire::Macro::Delayed::Job.job_queue_size(:default)
        # @example Calculate size across "default" and "mailer" queues
        #   HireFire::Macro::Delayed::Job.job_queue_size(:default, :mailer)
        def job_queue_size(*queues)
          with_connection do
            queues = normalize_queues(queues, allow_empty: true)
            query = waiting_scope

            case mapper
            when :active_record
              query = query.where("run_at <= ?", Time.now)
              query = query.where(queue: queues) if queues.any?
            when :mongoid
              query = query.where(run_at: {"$lte" => Time.now})
              query = query.in(queue: queues.to_a) if queues.any?
            end

            query.count
          end
        end

        # Counts in-flight (working) jobs: +failed_at+ null and +locked_at+ set.
        # Expired locks still count until cleared (no max_run_time reclaim). Never
        # folded into JQL/JQS. Plan records under +wrk+.
        #
        # @param queues [Array<String, Symbol>] (optional) Queue names. Empty = all.
        # @return [Integer] In-flight locked job count.
        # @raise [HireFire::Macro::Delayed::Job::MapperNotDetectedError] if neither an
        #   ActiveRecord nor a Mongoid mapper can be detected.
        # @example All queues
        #   HireFire::Macro::Delayed::Job.job_queue_working
        # @example Named queues
        #   HireFire::Macro::Delayed::Job.job_queue_working(:default, :mailer)
        def job_queue_working(*queues)
          with_connection do
            queues = normalize_queues(queues, allow_empty: true)

            case mapper
            when :active_record
              query = ::Delayed::Job.where(failed_at: nil).where.not(locked_at: nil)
              query = query.where(queue: queues) if queues.any?
            when :mongoid
              query = ::Delayed::Job.where(:failed_at => nil, :locked_at.ne => nil)
              query = query.in(queue: queues.to_a) if queues.any?
            end

            query.count
          end
        end

        private

        def waiting_scope
          ::Delayed::Job.where(failed_at: nil, locked_at: nil)
        end

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
