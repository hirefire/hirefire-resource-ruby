# frozen_string_literal: true

require "digest/sha1"
require_relative "legacy/sidekiq"

module HireFire
  module Macro
    module Sidekiq
      extend HireFire::Macro::Legacy::Sidekiq
      extend self

      # Calculates the maximum job queue latency across the specified queues.
      #
      # @param [Array<String, Symbol>] queues List of queue names.
      # @param [Hash] options The options to filter and control the latency calculation.
      # @option options [Boolean] :skip_retries (false) If set to true, skips checking the RetrySet for latencies.
      # @option options [Boolean] :skip_scheduled (false) If set to true, skips checking the ScheduledSet for latencies.
      # @return [Integer] Maximum job queue latency in seconds across the specified queues.
      # @raise [HireFire::Errors::MissingQueueError] Raised when no queue names are provided.
      # @example Job Queue Latency of the default queue
      #   HireFire::Macro::Sidekiq.job_queue_latency(:default)
      # @example Maximum Job Queue Latency across the default and mailer queues
      #   HireFire::Macro::Sidekiq.job_queue_latency(:default, :mailer)
      # @example Job Queue Latency of the default queue, not taking into account scheduled jobs
      #   HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_scheduled: true)
      # @example Job Queue Latency of the default queue, not taking into account retries
      #   HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_retries: true)
      def job_queue_latency(*queues, **options)
        JobQueueLatency.call(*queues, **options)
      end

      # Calculates the total job queue size across the specified queues.
      #
      # @param [Array<String, Symbol>] queues List of queue names.
      # @param [Hash] options The options to filter and control the count.
      # @option options [Boolean] :server (false) If true, use server-side Lua to count jobs.
      # @option options [Boolean] :skip_retries (false) If true, skip counting jobs in retry queues.
      # @option options [Boolean] :skip_scheduled (false) If true, skip counting jobs in scheduled queues.
      # @option options [Boolean] :skip_working (false) If true, skip counting already running jobs.
      # @option options [Integer, nil] :max_scheduled Maximum number of scheduled jobs to consider; nil indicates no maximum.
      # @return [Integer] Cumulative job queue size across the specified queues.
      # @raise [HireFire::Errors::MissingQueueError] Raised when no queue names are provided.
      # @example Job Queue Size of the default queue
      #   HireFire::Macro::Sidekiq.job_queue_size(:default)
      # @example Job Queue Size across the default and mailer queues
      #   HireFire::Macro::Sidekiq.job_queue_size(:default, :mailer)
      # @example Job Queue Size of the default queue, not taking into account scheduled jobs
      #   HireFire::Macro::Sidekiq.job_queue_size(:default, skip_scheduled: true)
      # @example Job Queue Size of the default queue, not taking into account retries
      #   HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true)
      # @example Job Queue Size of the default queue, not taking into account running jobs
      #   HireFire::Macro::Sidekiq.job_queue_size(:default, skip_working: true)
      # @example Job Queue Size of the default queue, using server-side aggregation
      #   HireFire::Macro::Sidekiq.job_queue_size(:default, server: true)
      # @example Job Queue Size of the default queue, limiting the counting of scheduled jobs to 100
      #   HireFire::Macro::Sidekiq.job_queue_size(:default, max_scheduled: 100)
      def job_queue_size(*queues, **options)
        JobQueueSize.call(*queues, **options)
      end

      module Common
        private

        # Iterates over each job in a Sidekiq set (e.g., ScheduledSet, RetrySet) in ascending order
        # based on their score. This method efficiently enumerates jobs that are scheduled to be
        # executed without having to traverse through potentially large numbers of jobs scheduled
        # for the distant future by allowing for efficient early breaks when iterating.
        #
        # @param [Sidekiq::JobSet, Sidekiq::ScheduledSet, Sidekiq::RetrySet] set The Sidekiq set to iterate over.
        # @yield [Sidekiq::SortedEntry] Yields each job in the set to the given block in ascending order based on score.
        # @return [void]
        def find_each_in_set(set)
          cursor = 0
          batch = 1000

          loop do
            elements = ::Sidekiq.redis do |connection|
              connection.zrange set.name, cursor, cursor + batch - 1, withscores: true
            end

            break if elements.empty?

            elements.each do |element, score|
              yield ::Sidekiq::SortedEntry.new(self, score, element)
            end

            cursor += batch
          end
        end
      end

      module JobQueueLatency
        extend Common
        extend self

        # @see HireFire::Macro::Sidekiq.job_queue_latency
        def call(*queues, skip_retries: false, skip_scheduled: false)
          queues = Utility.construct_queues(queues)
          latencies = [find_latency_in_queues(queues)]
          latencies << find_latency_in_set(::Sidekiq::RetrySet.new, queues) unless skip_retries
          latencies << find_latency_in_set(::Sidekiq::ScheduledSet.new, queues) unless skip_scheduled
          latencies.max.round
        end

        private

        # Calculates the maximum latency among the specified queues.
        # The latency for a job is determined by the difference between the current time
        # and the time when the oldest job was enqueued.
        #
        # @param queues [Array<String>] List of queue names to calculate latencies for.
        # @return [Integer] Maximum job queue latency (in seconds) observed across all queues.
        def find_latency_in_queues(queues)
          oldest_jobs = ::Sidekiq.redis do |conn|
            conn.pipelined do |pipeline|
              queues.each do |queue|
                pipeline.lindex("queue:#{queue}", -1)
              end
            end
          end

          max_latencies = oldest_jobs.map do |job_payload|
            job = JSON.parse(job_payload || "{}")
            job["enqueued_at"] ? Time.now.to_f - job["enqueued_at"] : 0
          end

          max_latencies.max.round
        end

        # Calculates the latency of the oldest job for each specified queue within a given Sidekiq set.
        # Latency is determined by the difference between the current time and the scheduled time (`job.at`) of the job.
        # It enumerates by scores in ascending order until it either finds a job with a matching queue, until the score
        # of a job exceeds the current time, or until we simply run out of jobs entirely. Once it matches a job that both
        # have a score lower than the current time, as well as a matching queue, it calculates the latency and then
        # breaks out of the loop and returns the latency.
        #
        # @param set [Sidekiq::RetrySet, Sidekiq::ScheduledSet] The set of jobs to inspect for latencies.
        # @param queues [Array<String>] List of queue names to calculate latencies for.
        # @return [Integer] Job Queue Latency (in seconds) for the earliest job from the specified queues.
        # @example Calculate Job Queue Latency of jobs in the retry set for specific queues
        #   find_latency_in_set(::Sidekiq::RetrySet.new, ["default", "critical"])
        def find_latency_in_set(set, queues)
          queue_set = Set.new(queues)
          max_latency = 0
          now = Time.now

          find_each_in_set(set) do |job|
            if job.at > now
              break
            elsif queue_set.include?(job.queue)
              max_latency = now - job.at
              break
            end
          end

          max_latency.round
        end
      end

      module JobQueueSize
        extend Common
        extend self

        # @see HireFire::Macro::Sidekiq.job_queue_size
        def call(*queues, server: false, **options)
          require "sidekiq/api"

          queues = Utility.construct_queues(queues)

          if server
            server_lookup(queues, **options)
          else
            client_lookup(queues, **options)
          end
        end

        private

        # Performs a client lookup of job counts based on provided queues and options.
        #
        # @param [Array<String>] queues The queues to check.
        # @param [Boolean] skip_retries If true, skip retry queues.
        # @param [Boolean] skip_scheduled If true, skip scheduled queues.
        # @param [Boolean] skip_working If true, skip working (in-progress) jobs.
        # @param [Integer, nil] max_scheduled Maximum number of scheduled jobs to consider; nil indicates no maximum.
        # @return [Integer] Total count of jobs.
        def client_lookup(queues, skip_retries: false, skip_scheduled: false, skip_working: false, max_scheduled: nil)
          count = count_enqueued(queues)
          count += count_scheduled(queues, max_scheduled) unless skip_scheduled
          count += count_retries(queues) unless skip_retries
          count += count_working(queues) unless skip_working
          count
        end

        # Counts the number of enqueued jobs in the given queues.
        #
        # @param [Array<String>] queues An array of Sidekiq queue names.
        # @return [Integer] The total number of enqueued jobs across the specified queues.
        def count_enqueued(queues)
          ::Sidekiq.redis do |conn|
            conn.pipelined do |pipeline|
              queues.each { |name| pipeline.llen("queue:#{name}") }
            end
          end.sum
        end

        # Counts the number of jobs in the scheduled set for the given queues that are scheduled to run as of now.
        # This method uses the `find_each_in_set` helper to iterate through the scheduled set in ascending order
        # based on their scheduled time. The counting stops when it reaches a job scheduled for a future time
        # or when the count reaches the specified maximum (if provided).
        #
        # @param queues [Array<String>] An array of Sidekiq queue names to filter by.
        # @param max [Integer, nil] The maximum number of jobs to count. If specified, counting stops once this limit is reached.
        # @return [Integer] The total number of jobs in the scheduled set for the specified queues up to now or the specified maximum.
        def count_scheduled(queues, max = nil)
          count, now = 0, Time.now

          find_each_in_set(::Sidekiq::ScheduledSet.new) do |job|
            if job.at > now || max && count >= max
              break
            elsif queues.include?(job["queue"])
              count += 1
            end
          end

          count
        end

        # Counts the number of jobs in the retry set for the specified queues that are scheduled to run as of now.
        # This method uses the `find_each_in_set` helper to iterate through the retry set in ascending order
        # based on their retry time. The counting process stops when it reaches a job that is set to retry at a future time.
        #
        # @param queues [Array<String>] An array of Sidekiq queue names to filter by.
        # @return [Integer] The total number of jobs in the retry set for the specified queues that are scheduled to run up to now.
        def count_retries(queues)
          count = 0
          now = Time.now

          find_each_in_set(::Sidekiq::RetrySet.new) do |job|
            if job.at > now
              break
            elsif queues.include?(job["queue"])
              count += 1
            end
          end

          count
        end

        # Counts the number of working jobs in the given queues that are scheduled to run now.
        #
        # @param [Array<String>] queues An array of Sidekiq queue names.
        # @return [Integer] The total number of working jobs in the queues up to the specified time.
        def count_working(queues)
          now = Time.now.to_i

          ::Sidekiq::Workers.new.count do |key, tid, job|
            queues.include?(job["queue"]) && job["run_at"] <= now
          end
        end

        # Server-side script to efficiently count jobs in Redis.
        SERVER_SIDE_SCRIPT = <<~LUA
          local tonumber = tonumber
          local cjson_decode = cjson.decode

          -- Counts the total number of jobs in the given queues
          local function count_in_queues(queues)
             local count = 0

             for name, _ in pairs(queues) do
                count = count + redis.call('llen', 'queue:' .. name)
             end

             return count
          end

          -- Counts the number of jobs in a sorted set up to an optional maximum limit
          local function count_in_sorted_set(queues, set, now, max)
             local count = 0
             local limit = 100
             local offset = 0
             local jobs

             repeat
                jobs = redis.call('zrangebyscore', set, '-inf', now, 'LIMIT', offset, limit)
                offset = offset + limit

                for i = 1, #jobs do
                   local job = cjson_decode(jobs[i])

                   if job and queues[job.queue] then
                      count = count + 1
                   end
                end
             until #jobs == 0 or (max > 0 and count >= max)

             return count
          end

          -- Counts the number of jobs currently in progress
          local function count_in_progress(queues)
             local count = 0
             local cursor = '0'

             repeat
                local process_sets = redis.call('SSCAN', 'processes', cursor)
                cursor = process_sets[1]

                for _, process_key in ipairs(process_sets[2]) do
                   local worker_key = process_key .. ':work'
                   local worker_data = redis.call('HGETALL', worker_key)

                   for i = 2, #worker_data, 2 do
                      local worker = cjson_decode(worker_data[i])

                      if queues[worker.queue] then
                         count = count + 1
                      end
                   end
                end
             until cursor == '0'

             return count
          end

          -- Set initial variables using ARGV input and initial values
          local now            = tonumber(ARGV[1])
          local max_scheduled  = tonumber(ARGV[2])
          local skip_scheduled = tonumber(ARGV[3]) == 1
          local skip_retries   = tonumber(ARGV[4]) == 1
          local skip_working   = tonumber(ARGV[5]) == 1

          -- Set the list of queues to count
          local queues = {}
          for i = 6, #ARGV do
             queues[ARGV[i]] = true
          end

          -- Count the total number of jobs across all queues
          local in_queues_counts = count_in_queues(queues)

          -- Count the jobs in all schedule queues, if requested
          local in_schedule_counts = 0
          if not skip_scheduled then
             in_schedule_counts = count_in_sorted_set(queues, 'schedule', now, max_scheduled)
          end

          -- Count the jobs in all retry queues, if requested
          local in_retry_counts = 0
          if not skip_retries then
             in_retry_counts = count_in_sorted_set(queues, 'retry', now, 0)
          end

          -- Count the jobs in all working queues, if requested
          local in_progress_counts = 0
          if not skip_working then
             in_progress_counts = count_in_progress(queues)
          end

          -- Return the aggregated result
          return in_queues_counts + in_schedule_counts + in_retry_counts + in_progress_counts
        LUA

        SERVER_SIDE_SCRIPT_SHA = Digest::SHA1.hexdigest(SERVER_SIDE_SCRIPT).freeze

        # Count the number of jobs on the server side.
        #
        # @param [Array<String>] queues A list of queue names.
        # @param [Boolean] skip_scheduled If true, skip scheduled jobs.
        # @param [Boolean] skip_retries If true, skip retry queues.
        # @param [Boolean] skip_working If true, skip working (in-progress) jobs.
        # @param [Integer] max_scheduled Maximum number of scheduled jobs to consider; 0 indicates no maximum.
        # @return [Integer] Total count of jobs.
        def server_lookup(queues, skip_scheduled: false, skip_retries: false, skip_working: false, max_scheduled: 0)
          ::Sidekiq.redis do |connection|
            now = Time.now.to_i
            skip_scheduled = skip_scheduled ? 1 : 0
            skip_retries = skip_retries ? 1 : 0
            skip_working = skip_working ? 1 : 0

            if defined?(::Sidekiq::RedisClientAdapter::CompatClient) && connection.is_a?(::Sidekiq::RedisClientAdapter::CompatClient)
              count_with_redis_client(connection, now, max_scheduled, skip_scheduled, skip_retries, skip_working, *queues)
            elsif defined?(::Redis) && connection.is_a?(::Redis)
              count_with_redis(connection, now, max_scheduled, skip_scheduled, skip_retries, skip_working, *queues)
            else
              raise "Unsupported Redis connection type: #{connection.class}"
            end
          end
        end

        # Count jobs using the Redis connection.
        #
        # @param [Redis::Client] connection Redis client connection.
        # @param [Array] args additional arguments for the server-side script.
        # @return [Integer] total count of jobs.
        def count_with_redis(connection, *args)
          connection.evalsha(SERVER_SIDE_SCRIPT_SHA, argv: args)
        rescue Redis::CommandError => e
          if e.message.include?("NOSCRIPT")
            connection.script(:load, SERVER_SIDE_SCRIPT)
            retry
          else
            raise
          end
        end

        # Count jobs using the RedisClient connection.
        #
        # @param [Sidekiq::RedisClientAdapter::CompatClient] connection Redis client connection.
        # @param [Array] args additional arguments for the server-side script.
        # @return [Integer] total count of jobs.
        def count_with_redis_client(connection, *args)
          connection.call("evalsha", SERVER_SIDE_SCRIPT_SHA, 0, *args)
        rescue RedisClient::CommandError => e
          if e.message.include?("NOSCRIPT")
            connection.call("script", "load", SERVER_SIDE_SCRIPT)
            retry
          else
            raise
          end
        end
      end
    end
  end
end
