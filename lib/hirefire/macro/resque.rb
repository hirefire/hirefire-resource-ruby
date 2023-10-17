# frozen_string_literal: true

require_relative "deprecated/resque"

module HireFire
  module Macro
    module Resque
      extend HireFire::Errors::JobQueueLatencyUnsupported
      extend HireFire::Macro::Deprecated::Resque
      extend HireFire::Utility
      extend self

      SIZE_METHODS = [
        :enqueued_size,
        :working_size,
        :scheduled_size
      ].freeze

      # Calculates the maximum job queue size using Resque. If no queues are specified, it
      # measures size across all available queues.
      #
      # @param queues [Array<String, Symbol>] (optional) Names of the queues for size measurement.
      #   If not provided, size is measured across all queues.
      # @return [Integer] Total job queue size.
      # @example Calculate size across all queues
      #   HireFire::Macro::Resque.job_queue_size
      # @example Calculate size for the "default" queue
      #   HireFire::Macro::Resque.job_queue_size(:default)
      # @example Calculate size across the "default" and "mailer" queues
      #   HireFire::Macro::Resque.job_queue_size(:default, :mailer)
      def job_queue_size(*queues)
        queues = normalize_queues(queues, allow_empty: true)

        SIZE_METHODS.sum do |size_method|
          method(size_method).call(queues)
        end
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

      def working_size(queues)
        ids = ::Resque.redis.smembers(:workers).compact

        workers = ::Resque.redis.pipelined do |pipeline|
          ids.each do |id|
            pipeline.get("worker:#{id}")
          end
        end.compact

        if queues.empty?
          workers.count
        else
          workers.count do |worker|
            queues.include?(::Resque.decode(worker)["queue"])
          end
        end
      end

      def scheduled_size(queues)
        cursor = 0
        batch = 1000
        total_size = 0
        current_time = Time.now.to_i

        loop do
          timestamps = ::Resque.redis.zrangebyscore(
            "delayed_queue_schedule",
            "-inf",
            current_time,
            limit: [cursor, batch]
          )

          break if timestamps.empty?

          if queues.empty?
            total_size += ::Resque.redis.pipelined do |pipeline|
              timestamps.each do |timestamp|
                pipeline.llen("delayed:#{timestamp}")
              end
            end.sum
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

                total_size += encoded_jobs.count do |encoded_job|
                  queues.include?(::Resque.decode(encoded_job)["queue"])
                end

                break if encoded_jobs.size < batch

                job_cursor += batch
              end
            end
          end

          break if timestamps.size < batch

          cursor += batch
        end

        total_size
      end

      private

      def registered_queues
        ::Resque.redis.keys("queue:*").map { |key| key[6..] }.to_set
      end
    end
  end
end
