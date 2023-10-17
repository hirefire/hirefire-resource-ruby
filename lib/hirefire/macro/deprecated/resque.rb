# frozen_string_literal: true

module HireFire
  module Macro
    module Deprecated
      # Provides backward compatibility with the deprecated Resque macro.
      # For new implementations, refer to {HireFire::Macro::Resque}.
      module Resque
        # Retrieves the total number of jobs in the specified Resque queue(s).
        #
        # This method counts the number of jobs in either specific queues or all queues if none are
        # specified. It includes both queued and in-progress jobs.
        #
        # @param queues [Array<String, Symbol>] Queue names to count jobs in.
        #   Pass an empty array or no arguments to count jobs in all queues.
        # @return [Integer] Total number of jobs in the specified queues.
        # @example Counting jobs in all queues
        #   HireFire::Macro::Resque.queue
        # @example Counting jobs in the "default" queue
        #   HireFire::Macro::Resque.queue("default")
        # @example Counting jobs in both "default" and "critical" queues
        #   HireFire::Macro::Resque.queue("default", "critical")
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
