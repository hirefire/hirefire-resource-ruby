# frozen_string_literal: true

require_relative "helpers/active_record_connection"
require_relative "../plan/hooks"
require_relative "../utility"
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

        PLAN_OPTION_SCHEMA = {
          Strategy::JQS => {
            "skip_working" => :boolean
          }.freeze
        }.freeze

        def library_loaded?
          !!defined?(::Delayed::Job)
        end

        def plan_options(strategy, options)
          extract_plan_options(strategy, options, PLAN_OPTION_SCHEMA)
        end

        def job_queue_latency(*queues, min_priority: nil, max_priority: nil)
          with_connection(::Delayed::Job) do
            oldest = oldest_run_at(due(waiting_scope, queues, min_priority, max_priority))
            oldest ? [Time.now - oldest, 0.0].max : 0.0
          end
        end

        def job_queue_size(*queues, skip_working: false, min_priority: nil, max_priority: nil)
          with_connection(::Delayed::Job) do
            query = skip_working ? waiting_scope : unfailed_scope

            due(query, queues, min_priority, max_priority).count
          end
        end

        def job_queue_working(*queues)
          with_connection(::Delayed::Job) do
            queues = normalize_queues(queues, allow_empty: true)

            case mapper
            when :active_record
              query = unfailed_scope.where("locked_at >= ?", lock_expiry)
              query = query.where(queue: queues) if queues.any?
            when :mongoid
              query = unfailed_scope.where(locked_at: {"$gte" => lock_expiry})
              query = query.in(queue: queues.to_a) if queues.any?
            end

            query.count
          end
        end

        private

        def due(query, queues, min_priority, max_priority)
          queues = normalize_queues(queues, allow_empty: true)

          case mapper
          when :active_record
            query = query.where("run_at <= ?", Time.now)
            query = query.where("priority >= ?", min_priority) unless min_priority.nil?
            query = query.where("priority <= ?", max_priority) unless max_priority.nil?
            query = query.where(queue: queues) if queues.any?
          when :mongoid
            query = query.where(run_at: {"$lte" => Time.now})
            query = query.where(priority: {"$gte" => min_priority}) unless min_priority.nil?
            query = query.where(priority: {"$lte" => max_priority}) unless max_priority.nil?
            query = query.in(queue: queues.to_a) if queues.any?
          end

          query
        end

        def oldest_run_at(query)
          case mapper
          when :active_record
            query.minimum(:run_at)
          when :mongoid
            query.order(run_at: :asc).only(:run_at).first&.run_at
          end
        end

        def unfailed_scope
          ::Delayed::Job.where(failed_at: nil)
        end

        def waiting_scope
          case mapper
          when :active_record
            unfailed_scope.where("locked_at IS NULL OR locked_at < ?", lock_expiry)
          when :mongoid
            unfailed_scope.where("$or" => [{locked_at: nil}, {locked_at: {"$lt" => lock_expiry}}])
          end
        end

        def lock_expiry
          Time.now - ::Delayed::Worker.max_run_time
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
