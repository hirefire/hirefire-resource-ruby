# frozen_string_literal: true

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

      SIZE_METHODS = [
        :enqueued_size,
        :scheduled_size
      ].freeze
      WALK_BATCH = 1_000
      WALK_JOB_BUDGET = 50_000
      WALK_TIME_BUDGET = 2.0

      PLAN_OPTION_SCHEMA = {
        "jqs" => {
          "skip_working" => :boolean
        }.freeze
      }.freeze

      def plan_options(strategy, options)
        extract_plan_options(strategy, options, PLAN_OPTION_SCHEMA)
      end

      def job_queue_size(*queues, skip_working: false)
        queues = normalize_queues(queues, allow_empty: true)

        size = SIZE_METHODS.sum do |size_method|
          method(size_method).call(queues)
        end

        skip_working ? size : size + working_size(queues)
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
        batch = WALK_BATCH
        total_size = 0
        current_time = Time.now.to_i
        min_score = "-inf"
        jobs_seen = 0
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        loop do
          timestamps = ::Resque.redis.zrangebyscore(
            "delayed_queue_schedule",
            min_score,
            current_time,
            limit: [0, batch]
          )

          break if timestamps.empty?

          if queues.empty?
            lengths = ::Resque.redis.pipelined do |pipeline|
              timestamps.each do |timestamp|
                pipeline.llen("delayed:#{timestamp}")
              end
            end
            jobs_seen += lengths.sum
            raise_if_walk_budget_exceeded!("delayed", jobs_seen, started)
            total_size += lengths.sum
          else
            timestamps.each do |timestamp|
              job_cursor = 0

              loop do
                encoded_jobs = ::Resque.redis.lrange(
                  "delayed:#{timestamp}",
                  job_cursor,
                  job_cursor + batch - 1
                )

                break if encoded_jobs.empty?

                jobs_seen += encoded_jobs.size
                raise_if_walk_budget_exceeded!("delayed", jobs_seen, started)

                total_size += encoded_jobs.count do |encoded_job|
                  queues.include?(encoded_queue(encoded_job))
                end

                break if encoded_jobs.size < batch

                job_cursor += batch
              end
            end
          end

          break if timestamps.size < batch

          min_score = "(#{timestamps.last}"
        end

        total_size
      end

      def working_size(queues)
        total_size = 0
        jobs_seen = 0
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        ::Resque.redis.smembers(:workers).each_slice(WALK_BATCH) do |ids|
          encoded_jobs = ::Resque.redis.pipelined do |pipeline|
            ids.each do |id|
              pipeline.get("worker:#{id}")
            end
          end.compact

          jobs_seen += encoded_jobs.size
          raise_if_walk_budget_exceeded!("worker", jobs_seen, started)

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

      def raise_if_walk_budget_exceeded!(walk, jobs_seen, started)
        return if jobs_seen < WALK_JOB_BUDGET &&
          (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) < WALK_TIME_BUDGET

        raise HireFire::Errors::SampleIncomplete, "Resque #{walk} walk exceeded budget"
      end

      def encoded_queue(encoded_job)
        payload = ::Resque.decode(encoded_job)
        return unless payload.is_a?(Hash)

        queue = payload["queue"]
        return if queue.nil? || queue == ""

        queue
      rescue ::Resque::Helpers::DecodeException, TypeError
        nil
      end

      def registered_queues
        ::Resque.queues.to_set
      end
    end
  end
end
