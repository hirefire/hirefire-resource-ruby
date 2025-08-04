# frozen_string_literal: true

require_relative "deprecated/delayed_job"

module HireFire
  module Macro
    module Delayed
      module Job
        extend HireFire::Macro::Deprecated::Delayed::Job
        extend HireFire::Utility
        extend self

        class MapperNotDetectedError < StandardError; end

        # Calculates the maximum job queue latency using Delayed::Job. If no queues are specified,
        # it measures latency across all available queues. This method supports both ActiveRecord
        # and Mongoid mappers.
        #
        # @param queues [Array<String, Symbol>] (optional) Names of the queues for latency
        #   measurement. If not provided, latency is measured across all queues.
        # @return [Float] Maximum job queue latency in seconds.
        # @example Calculate latency across all queues
        #   HireFire::Macro::Delayed::Job.job_queue_latency
        # @example Calculate latency for the "default" queue
        #   HireFire::Macro::Delayed::Job.job_queue_latency(:default)
        # @example Calculate latency across "default" and "mailer" queues
        #   HireFire::Macro::Delayed::Job.job_queue_latency(:default, :mailer)
        def job_queue_latency(*queues)
          queues = normalize_queues(queues, allow_empty: true)
          query = ::Delayed::Job.where(failed_at: nil).order(run_at: :asc)

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

        # Calculates the total job queue size using Delayed::Job. If no queues are specified, it
        # measures size across all available queues. This method supports both ActiveRecord and
        # Mongoid mappers.
        #
        # @param queues [Array<String, Symbol>] (optional) Names of the queues for size measurement.
        #   If not provided, size is measured across all queues.
        # @return [Integer] Total job queue size.
        # @example Calculate size across all queues
        #   HireFire::Macro::Delayed::Job.job_queue_size
        # @example Calculate size of the "default" queue
        #   HireFire::Macro::Delayed::Job.job_queue_size(:default)
        # @example Calculate size across "default" and "mailer" queues
        #   HireFire::Macro::Delayed::Job.job_queue_size(:default, :mailer)
        def job_queue_size(*queues)
          queues = normalize_queues(queues, allow_empty: true)
          query = ::Delayed::Job.where(failed_at: nil)

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

        private

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
