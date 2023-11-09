# frozen_string_literal: true

module HireFire
  module Macro
    module Resque
      extend HireFire::Errors::QueueMethodRenamed
      extend HireFire::Errors::JobQueueLatencyUnsupported
      extend self

      # Calculates the total job queue size across the specified queues.
      #
      # @param queues [Array<String, Symbol>] the list of queues to count.
      # @return [Integer] Cumulative job queue size across the specified queues.
      # @raise [HireFire::Errors::MissingQueueError] Raised when no queue names are provided.
      # @example Job Queue Size in the default queue
      #   HireFire::Macro::Resque.job_queue_size(:default)
      # @example Job Queue Size across the default and mailer queues
      #   HireFire::Macro::Resque.job_queue_size(:default, :mailer)
      def job_queue_size(*queues)
        queues = Utility.construct_queues(queues)
        count_enqueued(queues) + count_working(queues) + count_scheduled(queues)
      end

      private

      # Counts the number of enqueued jobs in the specified queues.
      #
      # @param queues [Array<String, Symbol>] the list of queues to count enqueued jobs from.
      # @return [Integer] the number of enqueued jobs.
      def count_enqueued(queues)
        ::Resque.redis.pipelined do |pipeline|
          queues.each do |queue|
            pipeline.llen("queue:#{queue}")
          end
        end.sum
      end

      # Counts the number of workers currently processing jobs from the specified queues.
      #
      # @param queues [Array<String, Symbol>] the list of queues to count working jobs from.
      # @return [Integer] the number of jobs currently being processed by workers.
      def count_working(queues)
        ids = ::Resque.redis.smembers(:workers).compact

        workers = ::Resque.redis.pipelined do |pipeline|
          ids.each do |id|
            pipeline.get("worker:#{id}")
          end
        end.compact

        workers.count do |worker|
          queues.include?(::Resque.decode(worker)["queue"])
        end
      end

      # Counts the number of scheduled jobs for the specified queues that are set to run immediately.
      #
      # This method is built on the assumption that resque-scheduler is utilized to schedule jobs for
      # future execution. It will only count jobs that are due for immediate processing.
      #
      # Additionally, this method is compatible with resque-retry. Underneath, resque-retry leverages
      # resque-scheduler to determine when failed jobs should be retried. Consequently, jobs slated for
      # a retry are also accounted for.
      #
      # This method:
      # 1. Fetches all pertinent timestamps from "delayed_queue_schedule".
      # 2. Iterates over each timestamp to extract the actual job details.
      # 3. Evaluates if the job is associated with any of the specified queues and, if so, increments the count.
      #
      # @param queues [Array<String, Symbol>] The list of queues from which to count scheduled jobs.
      # @return [Integer] The number of immediate scheduled jobs for the given queues.
      def count_scheduled(queues)
        cursor = 0
        batch = 1000
        total_count = 0
        current_time = Time.now.to_i

        loop do
          timestamps = ::Resque.redis.zrangebyscore("delayed_queue_schedule", "-inf", current_time, limit: [cursor, batch])

          break if timestamps.empty?

          timestamps.each do |timestamp|
            job_cursor = 0

            loop do
              encoded_jobs = ::Resque.redis.lrange("delayed:#{timestamp}", job_cursor, job_cursor + batch - 1)

              break if encoded_jobs.empty?

              total_count += encoded_jobs.count do |encoded_job|
                queues.include?(::Resque.decode(encoded_job)["queue"])
              end

              break if encoded_jobs.size < batch

              job_cursor += batch
            end
          end

          break if timestamps.size < batch

          cursor += batch
        end

        total_count
      end
    end
  end
end
