# frozen_string_literal: true

require_relative "helpers/active_record_connection"
require_relative "../plan/hooks"
require_relative "deprecated/queue_classic"

module HireFire
  module Macro
    module QC
      extend HireFire::Macro::Deprecated::QC
      extend HireFire::Utility
      extend HireFire::Macro::Helpers::ActiveRecordConnection
      extend HireFire::Plan::Hooks
      extend self

      # Calculates the maximum job queue latency using Queue Classic. If no queues are specified, it
      # measures latency across all available queues.
      #
      # Waiting set only: due jobs (`scheduled_at` ≤ now) that are unlocked (`locked_at` null).
      # Locked (working) jobs are excluded. Future `scheduled_at` is not measured.
      #
      # @param queues [Array<String, Symbol>] (optional) Names of the queues for latency
      #   measurement. If not provided, latency is measured across all queues.
      # @return [Float] Maximum job queue latency in seconds.
      # @example Calculate latency across all queues
      #   HireFire::Macro::QC.job_queue_latency
      # @example Calculate latency for the "default" queue
      #   HireFire::Macro::QC.job_queue_latency(:default)
      # @example Calculate latency across "default" and "mailer" queues
      #   HireFire::Macro::QC.job_queue_latency(:default, :mailer)
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

      # Calculates the total job queue size using Queue Classic. If no queues are specified, it
      # measures size across all available queues.
      #
      # Waiting set only: due jobs (`scheduled_at` ≤ now) that are unlocked (`locked_at` null).
      # Locked (working) jobs are excluded. Future `scheduled_at` is not counted.
      #
      # @param queues [Array<String, Symbol>] (optional) Names of the queues for size measurement.
      #   If not provided, size is measured across all queues.
      # @return [Integer] Total job queue size (waiting set: due + unlocked).
      # @example Calculate size across all queues
      #   HireFire::Macro::QC.job_queue_size
      # @example Calculate size for the "default" queue
      #   HireFire::Macro::QC.job_queue_size(:default)
      # @example Calculate size across "default" and "mailer" queues
      #   HireFire::Macro::QC.job_queue_size(:default, :mailer)
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

      # Counts in-flight (working) jobs: +locked_at+ set. Never folded into JQL/JQS.
      # Plan records under +wrk+.
      #
      # @param queues [Array<String, Symbol>] (optional) Queue names. Empty = all.
      # @return [Integer] In-flight locked job count.
      # @example All queues
      #   HireFire::Macro::QC.job_queue_working
      # @example Named queues
      #   HireFire::Macro::QC.job_queue_working(:default, :mailer)
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
