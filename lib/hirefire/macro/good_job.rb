# frozen_string_literal: true

require_relative "helpers/active_record_connection"
require_relative "../plan/hooks"
require_relative "../utility"
require_relative "helpers/good_job"
require_relative "deprecated/good_job"

module HireFire
  module Macro
    module GoodJob
      extend HireFire::Macro::Utility
      extend HireFire::Macro::Helpers::ActiveRecordConnection
      extend HireFire::Plan::Hooks
      extend HireFire::Macro::Helpers::GoodJob
      extend HireFire::Macro::Deprecated::GoodJob
      extend self

      PLAN_OPTION_SCHEMA = {
        Strategy::JQS => {
          "skip_working" => :boolean
        }.freeze
      }.freeze

      SKIP_LOCKED_CLAIM = "lock_type = 1 AND locked_by_id IS NOT NULL"
      NO_SKIP_LOCKED_CLAIM = "lock_type IS DISTINCT FROM 1 OR locked_by_id IS NULL"

      def plan_options(strategy, options)
        extract_plan_options(strategy, options, PLAN_OPTION_SCHEMA)
      end

      def job_queue_latency(*queues)
        with_connection(good_job_class) do
          due_at = Arel.sql("COALESCE(scheduled_at, created_at)")
          oldest = [ready_jobs(queues), interrupted_jobs(queues)].filter_map { |jobs| jobs.minimum(due_at) }.min
          oldest ? [Time.now - oldest, 0.0].max : 0.0
        end
      end

      def job_queue_size(*queues, skip_working: false)
        with_connection(good_job_class) do
          started = skip_working ? interrupted_jobs(queues) : started_jobs(queues)
          ready_jobs(queues).count + started.count
        end
      end

      def job_queue_working(*queues)
        with_connection(good_job_class) do
          working_jobs(queues).count
        end
      end

      private

      def unfinished_jobs(queues)
        queues = normalize_queues(queues, allow_empty: true)
        query = good_job_class.where(finished_at: nil)
        queues.any? ? query.where(queue_name: queues) : query
      end

      def ready_jobs(queues)
        query = unfinished_jobs(queues).where(performed_at: nil)
        query = query.where.not(error_event: discarded_enum).or(query.where(error_event: nil)) if error_event_supported?
        query.where("scheduled_at <= ?", Time.now).or(query.where(scheduled_at: nil))
      end

      def started_jobs(queues)
        unfinished_jobs(queues).where.not(performed_at: nil)
      end

      def working_jobs(queues)
        started = started_jobs(queues)
        return started.advisory_locked unless lock_type_supported?

        started.advisory_locked.or(started.advisory_unlocked.where(SKIP_LOCKED_CLAIM))
      end

      def interrupted_jobs(queues)
        unlocked = started_jobs(queues).advisory_unlocked
        lock_type_supported? ? unlocked.where(NO_SKIP_LOCKED_CLAIM) : unlocked
      end
    end
  end
end
