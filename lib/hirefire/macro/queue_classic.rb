# frozen_string_literal: true

require_relative "deprecated/queue_classic"

module HireFire
  module Macro
    module QC
      extend HireFire::Macro::Deprecated::QC
      extend HireFire::Utility
      extend self

      # Calculates the maximum job queue latency using Queue Classic. If no queues are specified, it
      # measures latency across all available queues.
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
        queues = normalize_queues(queues, allow_empty: true)

        query = <<~SQL
          SELECT EXTRACT(EPOCH FROM (now() - scheduled_at)) AS latency
          FROM #{::QC.table_name}
          WHERE scheduled_at <= now()
          #{filter_by_queues_if_any(queues)}
          ORDER BY scheduled_at ASC
          LIMIT 1
        SQL

        connection = ::QC.default_conn_adapter

        result = if queues.any?
          connection.execute(query, "{#{queues.to_a.join(",")}}")
        else
          connection.execute(query)
        end

        (result && result["latency"]) ? result["latency"].to_f : 0.0
      end

      # Calculates the total job queue size using Queue Classic. If no queues are specified, it
      # measures size across all available queues.
      #
      # @param queues [Array<String, Symbol>] (optional) Names of the queues for size measurement.
      #   If not provided, size is measured across all queues.
      # @return [Integer] Total job queue size.
      # @example Calculate size across all queues
      #   HireFire::Macro::QC.job_queue_size
      # @example Calculate size for the "default" queue
      #   HireFire::Macro::QC.job_queue_size(:default)
      # @example Calculate size across "default" and "mailer" queues
      #   HireFire::Macro::QC.job_queue_size(:default, :mailer)
      def job_queue_size(*queues)
        queues = normalize_queues(queues, allow_empty: true)

        query = <<~SQL
          SELECT COUNT(*) FROM #{::QC.table_name}
          WHERE scheduled_at <= now()
          #{filter_by_queues_if_any(queues)}
        SQL

        connection = ::QC.default_conn_adapter

        result = if queues.any?
          connection.execute(query, "{#{queues.to_a.join(",")}}")
        else
          connection.execute(query)
        end

        result["count"].to_i
      end

      private

      def filter_by_queues_if_any(queues)
        queues.any? ? "AND q_name = ANY($1::text[])" : ""
      end
    end
  end
end
