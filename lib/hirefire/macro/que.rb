# frozen_string_literal: true

require_relative "../plan/hooks"
require_relative "deprecated/que"

module HireFire
  module Macro
    module Que
      extend HireFire::Macro::Deprecated::Que
      extend HireFire::Utility
      extend HireFire::Plan::Hooks
      extend self

      VERSION_1_0_0 = Gem::Version.new("1.0.0")

      # Calculates the maximum job queue latency using Que. If no queues are specified, it
      # measures latency across all available queues.
      #
      # Waiting set only: due unfinished/unexpired jobs (v1+) that are not session
      # advisory-locked. Locked (working) jobs are excluded. Future `run_at` is not measured.
      # Retries with `error_count > 0` still count when due and unlocked (do not copy Que AR
      # `ready`, which drops errored rows).
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
      # Waiting set only: due unfinished/unexpired jobs (v1+) that are not session
      # advisory-locked. Locked (working) jobs are excluded. Future `run_at` is not counted.
      # Retries with `error_count > 0` still count when due and unlocked (do not copy Que AR
      # `ready`, which drops errored rows). No `skip_working` flag.
      #
      # @param queues [Array<String, Symbol>] (optional) Names of the queues for size measurement.
      #   If not provided, size is measured across all queues.
      # @return [Integer] Total job queue size (waiting set: due + not advisory-locked).
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
        queues = normalize_queues(queues, allow_empty: true)
        query = <<~SQL
          SELECT run_at
          FROM que_jobs
          WHERE run_at <= NOW()
          #{not_advisory_locked_sql}
          #{filter_by_queues_if_any(queues)}
          ORDER BY run_at ASC
          LIMIT 1
        SQL

        query_job_queue_latency(query, queues)
      end

      def job_queue_latency_v1_v2(*queues)
        queues = normalize_queues(queues, allow_empty: true)
        query = <<~SQL
          SELECT run_at
          FROM que_jobs
          WHERE run_at <= NOW()
          AND finished_at IS NULL
          AND expired_at IS NULL
          #{not_advisory_locked_sql}
          #{filter_by_queues_if_any(queues)}
          ORDER BY run_at ASC
          LIMIT 1
        SQL

        query_job_queue_latency(query, queues)
      end

      def job_queue_size_v0(*queues)
        queues = normalize_queues(queues, allow_empty: true)
        query = <<~SQL
          SELECT COUNT(*) AS job_queue_size
          FROM que_jobs
          WHERE run_at <= NOW()
          #{not_advisory_locked_sql}
          #{filter_by_queues_if_any(queues)}
        SQL

        query_job_queue_size(query, queues)
      end

      def job_queue_size_v1_v2(*queues)
        queues = normalize_queues(queues, allow_empty: true)
        query = <<~SQL
          SELECT COUNT(*) AS job_queue_size
          FROM que_jobs
          WHERE run_at <= NOW()
          AND finished_at IS NULL
          AND expired_at IS NULL
          #{not_advisory_locked_sql}
          #{filter_by_queues_if_any(queues)}
        SQL

        query_job_queue_size(query, queues)
      end

      # Matches Que `job_stats` / locker: session advisory lock key is the job row id
      # (`job_id` on Que 0, `id` on Que 1+). `pg_locks` only (no `que_lockers` join).
      def not_advisory_locked_sql
        <<~SQL.chomp
          AND NOT EXISTS (
            SELECT 1
            FROM pg_locks
            WHERE locktype = 'advisory'
              AND (classid::bigint << 32) + objid::bigint = que_jobs.#{advisory_lock_id_column}
          )
        SQL
      end

      def advisory_lock_id_column
        (version < VERSION_1_0_0) ? "job_id" : "id"
      end

      def query_job_queue_latency(query, queues)
        result = ::Que.execute(query, queues.to_a).first
        result ? (Time.now - result[:run_at].to_time) : 0.0
      end

      def query_job_queue_size(query, queues)
        ::Que.execute(query, queues.to_a).first.fetch(:job_queue_size).to_i
      end

      def filter_by_queues_if_any(queues)
        return "" if queues.empty?
        placeholders = (1..queues.size).map { |i| "$#{i}" }.join(", ")
        "AND queue IN (#{placeholders})"
      end

      def version
        Gem::Version.new(defined?(::Que::Version) ? ::Que::Version : ::Que::VERSION)
      end
    end
  end
end
