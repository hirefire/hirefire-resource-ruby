# frozen_string_literal: true

require_relative "deprecated/que"

module HireFire
  module Macro
    module Que
      extend HireFire::Macro::Deprecated::Que
      extend HireFire::Utility
      extend self

      VERSION_1_0_0 = Gem::Version.new("1.0.0")

      # Calculates the maximum job queue latency using Que. If no queues are specified, it
      # measures latency across all available queues.
      #
      # @param queues [Array<String, Symbol>] (optional) Names of the queues for latency
      #   measurement. If not provided, latency is measured across all queues.
      # @return [Float] Maximum job queue latency in seconds.
      # @example Calculate latency across all queues
      #   HireFire::Macro::Que.job_queue_latency
      # @example Calculate latency for the "default" queue
      #   HireFire::Macro::Que.job_queue_latency(:default)
      # @example Calculate latency across "default" and "mailer" queues
      #   HireFire::Macro::Que.job_queue_latency(:default, :mailer)
      def job_queue_latency(*queues)
        if version < VERSION_1_0_0
          job_queue_latency_v0(*queues)
        else
          job_queue_latency_v1_v2(*queues)
        end
      end

      # Calculates the total job queue size using Que. If no queues are specified, it
      # measures size across all available queues.
      #
      # @param queues [Array<String, Symbol>] (optional) Names of the queues for size measurement.
      #   If not provided, size is measured across all queues.
      # @return [Integer] Total job queue size.
      # @example Calculate size across all queues
      #   HireFire::Macro::Que.job_queue_size
      # @example Calculate size for the "default" queue
      #   HireFire::Macro::Que.job_queue_size(:default)
      # @example Calculate size across "default" and "mailer" queues
      #   HireFire::Macro::Que.job_queue_size(:default, :mailer)
      def job_queue_size(*queues)
        if version < VERSION_1_0_0
          job_queue_size_v0(*queues)
        else
          job_queue_size_v1_v2(*queues)
        end
      end

      private

      def job_queue_latency_v0(*queues)
        query = <<~SQL
          SELECT run_at
          FROM que_jobs
          WHERE run_at <= NOW()
          #{filter_by_queues_if_any(queues)}
          ORDER BY run_at ASC
          LIMIT 1
        SQL

        query_job_queue_latency(query)
      end

      def job_queue_latency_v1_v2(*queues)
        query = <<~SQL
          SELECT run_at
          FROM que_jobs
          WHERE run_at <= NOW()
          AND finished_at IS NULL
          AND expired_at IS NULL
          #{filter_by_queues_if_any(queues)}
          ORDER BY run_at ASC
          LIMIT 1
        SQL

        query_job_queue_latency(query)
      end

      def job_queue_size_v0(*queues)
        query = <<~SQL
          SELECT COUNT(*) AS job_queue_size
          FROM que_jobs
          WHERE run_at <= NOW()
          #{filter_by_queues_if_any(queues)}
        SQL

        query_job_queue_size(query)
      end

      def job_queue_size_v1_v2(*queues)
        query = <<~SQL
          SELECT COUNT(*) AS job_queue_size
          FROM que_jobs
          WHERE run_at <= NOW()
          AND finished_at IS NULL
          AND expired_at IS NULL
          #{filter_by_queues_if_any(queues)}
        SQL

        query_job_queue_size(query)
      end

      def query_job_queue_latency(query)
        result = ::Que.execute(query).first
        result ? (Time.now - result[:run_at].to_time) : 0.0
      end

      def query_job_queue_size(query)
        ::Que.execute(query).first.fetch(:job_queue_size).to_i
      end

      def filter_by_queues_if_any(queues)
        queues = normalize_queues(queues, allow_empty: true)
        queues = queues.map(&method(:sanitize_sql)).join(", ")
        queues.empty? ? "" : "AND queue IN (#{queues})"
      end

      def sanitize_sql(value)
        "'" + value.to_s.gsub(/['"\\]/, '\\\\\\&') + "'"
      end

      def version
        Gem::Version.new(defined?(::Que::Version) ? ::Que::Version : ::Que::VERSION)
      end
    end
  end
end
