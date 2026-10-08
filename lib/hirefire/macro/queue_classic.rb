# frozen_string_literal: true

require_relative "helpers/active_record_connection"
require_relative "../plan/hooks"
require_relative "../utility"
require_relative "deprecated/queue_classic"

module HireFire
  module Macro
    module QC
      extend HireFire::Macro::Deprecated::QC
      extend HireFire::Macro::Utility
      extend HireFire::Macro::Helpers::ActiveRecordConnection
      extend HireFire::Plan::Hooks
      extend self

      PLAN_OPTION_SCHEMA = {
        Strategy::JQS => {
          "skip_working" => :boolean
        }.freeze
      }.freeze

      LOCKED = "locked_at IS NOT NULL AND locked_by IN (SELECT pid FROM pg_stat_activity)"
      UNLOCKED = "(locked_at IS NULL OR locked_by IS NULL OR locked_by NOT IN (SELECT pid FROM pg_stat_activity))"

      def library_loaded?
        !!defined?(::QC)
      end

      def plan_options(strategy, options)
        extract_plan_options(strategy, options, PLAN_OPTION_SCHEMA)
      end

      def job_queue_latency(*queues)
        with_connection do |connection|
          queues = normalize_queues(queues, allow_empty: true)
          query = <<~SQL
            SELECT EXTRACT(EPOCH FROM (now() - scheduled_at)) AS latency
            FROM #{::QC.table_name}
            WHERE scheduled_at <= now()
              AND #{UNLOCKED}
            #{filter_by_queues_if_any(queues, style: connection ? :ar : :dollar)}
            ORDER BY scheduled_at ASC
            LIMIT 1
          SQL
          result = query_one(connection, query, queues.to_a)
          result ? result["latency"].to_f : 0.0
        end
      end

      def job_queue_size(*queues, skip_working: false)
        with_connection do |connection|
          queues = normalize_queues(queues, allow_empty: true)
          query = <<~SQL
            SELECT COUNT(*) FROM #{::QC.table_name}
            WHERE scheduled_at <= now()
            #{"AND #{UNLOCKED}" if skip_working}
            #{filter_by_queues_if_any(queues, style: connection ? :ar : :dollar)}
          SQL
          result = query_one(connection, query, queues.to_a)
          result["count"].to_i
        end
      end

      def job_queue_working(*queues)
        with_connection do |connection|
          queues = normalize_queues(queues, allow_empty: true)
          query = <<~SQL
            SELECT COUNT(*) FROM #{::QC.table_name}
            WHERE #{LOCKED}
            #{filter_by_queues_if_any(queues, style: connection ? :ar : :dollar)}
          SQL
          result = query_one(connection, query, queues.to_a)
          result["count"].to_i
        end
      end

      private

      def filter_by_queues_if_any(queues, style:)
        placeholders = (style == :ar) ? ["?"] * queues.size : (1..queues.size).map { |i| "$#{i}" }
        "AND q_name IN (#{placeholders.join(", ")})" if queues.any?
      end

      def query_one(connection, query, binds)
        if connection
          sql = binds.any? ? ActiveRecord::Base.sanitize_sql_array([query, *binds]) : query
          connection.select_one(sql)
        else
          ::QC.default_conn_adapter.execute(query, *binds)
        end
      end
    end
  end
end
