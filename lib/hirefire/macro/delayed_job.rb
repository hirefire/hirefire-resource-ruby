# frozen_string_literal: true

require_relative "helpers/active_record_connection"
require_relative "../plan/hooks"
require_relative "deprecated/delayed_job"

module HireFire
  module Macro
    module Delayed
      module Job
        extend HireFire::Macro::Deprecated::Delayed::Job
        extend HireFire::Macro::Utility
        extend HireFire::Macro::Helpers::ActiveRecordConnection
        extend HireFire::Plan::Hooks
        extend self

        class MapperNotDetectedError < StandardError; end

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
              [Time.now - job.run_at, 0.0].max
            else
              0.0
            end
          end
        end

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
