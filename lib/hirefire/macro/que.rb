# frozen_string_literal: true

require_relative "../plan/hooks"
require_relative "deprecated/que"

module HireFire
  module Macro
    module Que
      extend HireFire::Macro::Deprecated::Que
      extend HireFire::Macro::Utility
      extend HireFire::Plan::Hooks
      extend self

      VERSION_1_0_0 = Gem::Version.new("1.0.0")

      def job_queue_latency(*queues)
        if version < VERSION_1_0_0
          job_queue_latency_v0(*queues)
        else
          job_queue_latency_v1_v2(*queues)
        end
      end

      def job_queue_size(*queues)
        if version < VERSION_1_0_0
          job_queue_size_v0(*queues)
        else
          job_queue_size_v1_v2(*queues)
        end
      end

      def job_queue_working(*queues)
        if version < VERSION_1_0_0
          job_queue_working_v0(*queues)
        else
          job_queue_working_v1_v2(*queues)
        end
      end

      private

      def job_queue_latency_v0(*queues)
        queues = normalize_queues(queues, allow_empty: true)
        query = <<~SQL
          SELECT EXTRACT(EPOCH FROM (NOW() - run_at)) AS latency
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
          SELECT EXTRACT(EPOCH FROM (NOW() - run_at)) AS latency
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

      def job_queue_working_v0(*queues)
        queues = normalize_queues(queues, allow_empty: true)
        query = <<~SQL
          SELECT COUNT(*) AS job_queue_working
          FROM que_jobs
          WHERE TRUE
          #{advisory_locked_sql}
          #{filter_by_queues_if_any(queues)}
        SQL

        query_job_queue_working(query, queues)
      end

      def job_queue_working_v1_v2(*queues)
        queues = normalize_queues(queues, allow_empty: true)
        query = <<~SQL
          SELECT COUNT(*) AS job_queue_working
          FROM que_jobs
          WHERE finished_at IS NULL
          AND expired_at IS NULL
          #{advisory_locked_sql}
          #{filter_by_queues_if_any(queues)}
        SQL

        query_job_queue_working(query, queues)
      end

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

      def advisory_locked_sql
        <<~SQL.chomp
          AND EXISTS (
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
        result ? (result[:latency] || result["latency"]).to_f : 0.0
      end

      def query_job_queue_size(query, queues)
        ::Que.execute(query, queues.to_a).first.fetch(:job_queue_size).to_i
      end

      def query_job_queue_working(query, queues)
        ::Que.execute(query, queues.to_a).first.fetch(:job_queue_working).to_i
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
