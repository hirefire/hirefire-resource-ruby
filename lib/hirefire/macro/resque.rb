# frozen_string_literal: true

require "time"
require_relative "../plan/hooks"
require_relative "../plan/size_only"
require_relative "../utility"
require_relative "deprecated/resque"

module HireFire
  module Macro
    module Resque
      extend HireFire::Macro::Deprecated::Resque
      extend HireFire::Macro::Utility
      extend HireFire::Plan::Hooks
      extend HireFire::Plan::SizeOnly
      extend HireFire::Errors::JobQueueLatencyUnsupported
      extend self

      WALK_BATCH = 1_000
      WALK_JOB_BUDGET = 50_000
      WALK_TIME_BUDGET = 2.0

      PLAN_OPTION_SCHEMA = {
        Strategy::JQS => {
          "skip_working" => :boolean
        }.freeze
      }.freeze

      def library_loaded?
        !!defined?(::Resque)
      end

      def plan_options(strategy, options)
        extract_plan_options(strategy, options, PLAN_OPTION_SCHEMA)
      end

      def job_queue_size(*queues, skip_working: false)
        queues = normalize_queues(queues, allow_empty: true)
        size = enqueued_size(queues) + scheduled_size(queues)

        skip_working ? size : size + working_size(queues)
      end

      def job_queue_working(*queues)
        working_size(normalize_queues(queues, allow_empty: true))
      end

      private

      def enqueued_size(queues)
        queues = registered_queues if queues.empty?

        ::Resque.redis.pipelined do |pipeline|
          queues.each do |queue|
            pipeline.llen("queue:#{queue}")
          end
        end.sum
      end

      def scheduled_size(queues)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return due_timestamp_pages.sum { |timestamps| delayed_lengths(timestamps, started) } if queues.empty?

        jobs_seen = 0
        due_timestamp_pages.sum do |timestamps|
          timestamps.sum do |timestamp|
            delayed_job_pages(timestamp).sum do |encoded_jobs|
              jobs_seen += encoded_jobs.size
              raise_if_walk_budget_exceeded!("delayed", started, jobs_seen: jobs_seen)
              encoded_jobs.count { |encoded_job| queues.include?(encoded_queue(encoded_job)) }
            end
          end
        end
      end

      def due_timestamp_pages
        return to_enum(__method__) unless block_given?

        now = Time.now.to_i
        min_score = "-inf"
        loop do
          timestamps = ::Resque.redis.zrangebyscore("delayed_queue_schedule", min_score, now, limit: [0, WALK_BATCH])
          break if timestamps.empty?

          yield timestamps
          break if timestamps.size < WALK_BATCH

          min_score = "(#{timestamps.last}"
        end
      end

      def delayed_job_pages(timestamp)
        return to_enum(__method__, timestamp) unless block_given?

        cursor = 0
        loop do
          encoded_jobs = ::Resque.redis.lrange("delayed:#{timestamp}", cursor, cursor + WALK_BATCH - 1)
          break if encoded_jobs.empty?

          yield encoded_jobs
          break if encoded_jobs.size < WALK_BATCH

          cursor += WALK_BATCH
        end
      end

      def delayed_lengths(timestamps, started)
        lengths = ::Resque.redis.pipelined do |pipeline|
          timestamps.each { |timestamp| pipeline.llen("delayed:#{timestamp}") }
        end
        raise_if_walk_budget_exceeded!("delayed", started)
        lengths.sum
      end

      def working_size(queues)
        total_size = 0
        jobs_seen = 0
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        live_worker_ids.each_slice(WALK_BATCH) do |ids|
          encoded_jobs = ::Resque.redis.pipelined do |pipeline|
            ids.each do |id|
              pipeline.get("worker:#{id}")
            end
          end.compact

          jobs_seen += encoded_jobs.size
          raise_if_walk_budget_exceeded!("worker", started, jobs_seen: jobs_seen)

          total_size += if queues.empty?
            encoded_jobs.size
          else
            encoded_jobs.count do |encoded_job|
              queues.include?(encoded_queue(encoded_job))
            end
          end
        end

        total_size
      end

      def live_worker_ids
        ids, heartbeats, server_time = ::Resque.redis.pipelined do |pipeline|
          pipeline.smembers(:workers)
          pipeline.hgetall("workers:heartbeat")
          pipeline.time
        end
        now = Time.at(server_time.first.to_i)

        ids.reject do |id|
          heartbeat_expired?(heartbeats[id], now)
        end
      end

      def heartbeat_expired?(heartbeat, now)
        return false unless heartbeat

        (now - Time.parse(heartbeat)).to_i > ::Resque.prune_interval
      rescue ArgumentError
        false
      end

      def raise_if_walk_budget_exceeded!(walk, started, jobs_seen: 0)
        return if jobs_seen < WALK_JOB_BUDGET &&
          (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) < WALK_TIME_BUDGET

        raise HireFire::Errors::SampleIncompleteError, "Resque #{walk} walk exceeded budget"
      end

      def encoded_queue(encoded_job)
        payload = JSON.parse(encoded_job)
        return unless payload.is_a?(Hash)

        queue = payload["queue"]
        return if queue.nil? || queue == ""

        queue
      rescue JSON::ParserError, TypeError
        nil
      end

      def registered_queues
        ::Resque.queues.to_set
      end
    end
  end
end
