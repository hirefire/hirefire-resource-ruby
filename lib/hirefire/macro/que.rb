# frozen_string_literal: true

require_relative "deprecated/que"

module HireFire
  module Macro
    module Que
      extend HireFire::Macro::Deprecated::Que
      extend self

      # Calculates the maximum job queue latency across the specified queues.
      #
      # @param queues [Array<String, Symbol>] The names of the queues to be included in the measurement of job queue latency.
      # @param priority [Integer, Range, nil] Optional priority filter.
      # @return [Integer] Maximum job queue latency in seconds across the specified queues.
      # @raise [HireFire::Errors::MissingQueueError] Raised when no queue names are provided.
      # @example Job Queue Latency for the default queue
      #   HireFire::Macro::Que.job_queue_latency(:default)
      # @example Maximum Job Queue Latency across the default and mailer queues
      #   HireFire::Macro::Que.job_queue_latency(:default, :mailer)
      # @example Job Queue Latency for the default queue, scoped to priority 3 jobs
      #   HireFire::Macro::Que.job_queue_latency(priority: 3)
      # @example Job Queue Latency for the default queue, scoped to priority 3 to 7 jobs
      #   HireFire::Macro::Que.job_queue_latency(priority: 3..7)
      def job_queue_latency(*queues, priority: nil)
        queues = Utility.construct_queues(queues)
        queue_names = queues.map { |q| sanitize_sql(q) }.join(", ")
        query = "SELECT run_at FROM que_jobs" \
          " WHERE run_at <= NOW()" \
          " AND finished_at IS NULL" \
          " AND expired_at IS NULL" \
          " AND queue IN (#{queue_names})"

        if priority.is_a?(Range)
          query += " AND priority BETWEEN #{priority.begin} AND #{priority.end}"
        elsif priority.is_a?(Integer)
          query += " AND priority = #{priority}"
        end

        # @TODO is this what we want? or should we just get the oldest run_at?
        # Check other macros
        query += " ORDER BY priority ASC, run_at ASC LIMIT 1"

        result = ::Que.execute(query).first
        result ? (Time.now - result[:run_at].to_time).round : 0
      end

      # Calculates the total job queue size across the specified queues.
      #
      # @param queues [Array<String, Symbol>] The names of the queues to be included in the measurement of job queue size.
      # @param priority [Integer, Range, nil] Optional priority filter.
      # @return [Integer] Cumulative job queue size across the specified queues.
      # @raise [HireFire::Errors::MissingQueueError] Raised when no queue names are provided.
      # @example Job Queue Size for the default queue
      #   HireFire::Macro::Que.job_queue_size(:default)
      # @example Job Queue Size across the default and mailer queues
      #   HireFire::Macro::Que.job_queue_size(:default, :mailer)
      # @example Job Queue Size for the default queue, scoped to priority 3 jobs
      #   HireFire::Macro::Que.job_queue_size(priority: 3)
      # @example Job Queue Size for the default queue, scoped to priority 3 to 7 jobs
      #   HireFire::Macro::Que.job_queue_size(priority: 3..7)
      def job_queue_size(*queues, priority: nil)
        queues = Utility.construct_queues(queues)
        queue_names = queues.map { |q| sanitize_sql(q) }.join(", ")
        query =
          "SELECT COUNT(*) AS total FROM que_jobs" \
          " WHERE run_at <= NOW()" \
          " AND finished_at IS NULL" \
          " AND expired_at IS NULL" \
          " AND queue IN (#{queue_names})"

        if priority.is_a?(Range)
          query += " AND priority BETWEEN #{priority.begin} AND #{priority.end}"
        elsif priority.is_a?(Integer)
          query += " AND priority = #{priority}"
        end

        ::Que.execute(query).first.fetch(:total).to_i
      end

      private

      # Basic SQL string sanitization.
      # We assume that the value is provided by a trusted source.
      #
      # @param value [String] the value to sanitize.
      # @return [String] the sanitized value.
      def sanitize_sql(value)
        "'" + value.to_s.gsub(/['"\\]/, '\\\\\\&') + "'"
      end
    end
  end
end
