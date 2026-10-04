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
        "jqs" => {
          "skip_working" => :boolean
        }.freeze
      }.freeze

      def plan_options(strategy, options)
        extract_plan_options(strategy, options, PLAN_OPTION_SCHEMA)
      end

      def job_queue_latency(*queues)
        with_connection do
          query = ready_jobs(*queues).order(Arel.sql("COALESCE(scheduled_at, created_at) ASC"))

          if (job = query.first)
            [Time.now - (job.scheduled_at || job.created_at), 0.0].max
          else
            0.0
          end
        end
      end

      def job_queue_size(*queues, skip_working: false)
        with_connection do
          size = ready_jobs(*queues).count
          skip_working ? size : size + working_jobs(*queues).count
        end
      end

      def job_queue_working(*queues)
        with_connection do
          working_jobs(*queues).count
        end
      end

      private

      def ready_jobs(*queues)
        queues = normalize_queues(queues, allow_empty: true)
        query = good_job_class
        query = query.where(queue_name: queues) if queues.any?
        query = query.where(finished_at: nil, performed_at: nil)
        query = query.where.not(error_event: discarded_enum).or(query.where(error_event: nil)) if error_event_supported?
        query.where("scheduled_at <= ?", Time.now).or(query.where(scheduled_at: nil))
      end

      def working_jobs(*queues)
        queues = normalize_queues(queues, allow_empty: true)
        query = good_job_class
        query = query.where(queue_name: queues) if queues.any?
        query.where(finished_at: nil).where.not(performed_at: nil)
      end
    end
  end
end
