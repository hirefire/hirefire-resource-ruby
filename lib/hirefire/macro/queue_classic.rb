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

      def job_queue_latency(*queues)
        with_connection do |connection|
          queues = normalize_queues(queues, allow_empty: true)
          query = <<~SQL
            SELECT EXTRACT(EPOCH FROM (now() - scheduled_at)) AS latency
            FROM #{::QC.table_name}
            WHERE scheduled_at <= now()
              AND locked_at IS NULL
            #{filter_by_queues_if_any(queues, style: connection ? :ar : :dollar)}
            ORDER BY scheduled_at ASC
            LIMIT 1
          SQL
          result = query_one(connection, query, queues.to_a)
          (result && result["latency"]) ? result["latency"].to_f : 0.0
        end
      end

      def job_queue_size(*queues)
        with_connection do |connection|
          queues = normalize_queues(queues, allow_empty: true)
          query = <<~SQL
            SELECT COUNT(*) FROM #{::QC.table_name}
            WHERE scheduled_at <= now()
              AND locked_at IS NULL
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
            WHERE locked_at IS NOT NULL
            #{filter_by_queues_if_any(queues, style: connection ? :ar : :dollar)}
          SQL
          result = query_one(connection, query, queues.to_a)
          result["count"].to_i
        end
      end

      private

      def filter_by_queues_if_any(queues, style:)
        return "" unless queues.any?

        placeholders =
          if style == :ar
            (["?"] * queues.size).join(", ")
          else
            (1..queues.size).map { |i| "$#{i}" }.join(", ")
          end
        "AND q_name IN (#{placeholders})"
      end

      def query_one(connection, query, binds)
        if connection
          sql = binds.any? ? ActiveRecord::Base.sanitize_sql_array([query, *binds]) : query
          connection.select_one(sql)
        elsif binds.any?
          ::QC.default_conn_adapter.execute(query, *binds)
        else
          ::QC.default_conn_adapter.execute(query)
        end
      end
    end
  end
end
