# frozen_string_literal: true

require_relative "deprecated/queue_classic"

module HireFire
  module Macro
    module QC
      extend HireFire::Macro::Deprecated::QC
      extend self

      # Calculates the maximum job queue latency across the specified queues.
      #
      # @param queues [Array<String, Symbol>] The names of the queues to be included in the measurement of job queue latency.
      # @return [Integer] Maximum job queue latency in seconds across the specified queues.
      # @raise [HireFire::Errors::MissingQueueError] Raised when no queue names are provided.
      # @example Job Queue Latency for the default queue
      #   HireFire::Macro::QC.job_queue_latency(:default)
      # @example Maximum Job Queue Latency across the default and mailer queues
      #   HireFire::Macro::QC.job_queue_latency(:default, :mailer)
      def job_queue_latency(*queues)
        queues_to_check = Utility.construct_queues(queues)

        query = <<~SQL
          SELECT EXTRACT(EPOCH FROM (now() - scheduled_at)) AS latency
          FROM #{::QC.table_name}
          WHERE q_name = ANY($1::text[]) AND scheduled_at <= now()
          ORDER BY scheduled_at ASC
          LIMIT 1
        SQL

        result = ::QC::Queue
          .new(queues_to_check.first)
          .conn_adapter
          .execute(query, "{#{queues_to_check.to_a.join(",")}}")

        (result && result["latency"]) ? result["latency"].to_f.round : 0
      end

      # Calculates the total job queue size across the specified queues.
      #
      # @param queues [Array<String, Symbol>] The names of the queues to be included in the measurement of job queue size.
      # @return [Integer] Cumulative job queue size across the specified queues.
      # @raise [HireFire::Errors::MissingQueueError] Raised when no queue names are provided.
      # @example Job Queue Size for the default queue
      #   HireFire::Macro::QC.job_queue_size(:default)
      # @example Job Queue Size across the default and mailer queues
      #   HireFire::Macro::QC.job_queue_size(:default, :mailer)
      def job_queue_size(*queues)
        queues_to_check = Utility.construct_queues(queues)

        formatted_queues = "{" + queues_to_check.to_a.join(",") + "}"

        query = <<~SQL
          SELECT COUNT(*) FROM #{::QC.table_name}
          WHERE q_name = ANY($1::text[]) AND scheduled_at <= now()
        SQL

        result = ::QC::Queue
          .new(queues_to_check.first)
          .conn_adapter
          .execute(query, formatted_queues)

        result["count"].to_i
      end
    end
  end
end
