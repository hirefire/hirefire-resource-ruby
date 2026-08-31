# frozen_string_literal: true

module HireFire
  module Macro
    module Deprecated
      module Resque
        def queue(*queues)
          queues = queues.flatten.map(&:to_s)
          queues = ::Resque.queues if queues.empty?

          return 0 if queues.empty?

          redis = ::Resque.redis
          worker_ids = Array(redis.smembers(:workers)).compact
          raw_jobs = redis.pipelined do |redis|
            worker_ids.map { |id| redis.get("worker:#{id}") }
          end
          jobs_in_progress = raw_jobs.map { |raw_job| ::Resque.decode(raw_job) || {} }

          jobs_in_queues = redis.pipelined do |redis|
            queues.map { |queue| redis.llen("queue:#{queue}") }
          end.map(&:to_i).sum

          in_progress_count = jobs_in_progress.count { |job| queues.include?(job["queue"]) }

          jobs_in_queues + in_progress_count
        end
      end
    end
  end
end
