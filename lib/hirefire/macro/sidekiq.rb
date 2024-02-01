# frozen_string_literal: true

require "digest/sha1"
require_relative "deprecated/sidekiq"

module HireFire
  module Macro
    module Sidekiq
      extend HireFire::Macro::Deprecated::Sidekiq
      extend self

      # Calculates the maximum job queue latency using Sidekiq. If no queues are specified, it
      # measures latency across all available queues.
      #
      # @param queues [Array<String, Symbol>] (optional) Names of the queues for latency
      #   measurement. If not provided, latency is measured across all queues.
      # @param options [Hash] Options to control and filter the latency calculation.
      # @option options [Boolean] :skip_retries (false) If true, skips the RetrySet in latency calculation.
      # @option options [Boolean] :skip_scheduled (false) If true, skips the ScheduledSet in latency calculation.
      # @return [Float] Maximum job queue latency in seconds.
      # @example Calculate latency across all queues
      #   HireFire::Macro::Sidekiq.job_queue_latency
      # @example Calculate latency for the "default" queue
      #   HireFire::Macro::Sidekiq.job_queue_latency(:default)
      # @example Calculate maximum latency across "default" and "mailer" queues
      #   HireFire::Macro::Sidekiq.job_queue_latency(:default, :mailer)
      # @example Calculate latency for the "default" queue, excluding scheduled jobs
      #   HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_scheduled: true)
      # @example Calculate latency for the "default" queue, excluding retries
      #   HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_retries: true)
      def job_queue_latency(*queues, **options)
        JobQueueLatency.call(*queues, **options)
      end

      # Calculates the total job queue size using Sidekiq. If no queues are specified, it measures
      # size across all available queues.
      #
      # @param queues [Array<String, Symbol>] (optional) Names of the queues for size measurement.
      #   If not provided, size is measured across all queues.
      # @param options [Hash] Options to control and filter the count.
      # @option options [Boolean] :server (false) If true, counts jobs server-side using Lua scripting.
      # @option options [Boolean] :skip_retries (false) If true, skips counting jobs in retry queues.
      # @option options [Boolean] :skip_scheduled (false) If true, skips counting jobs in scheduled queues.
      # @option options [Boolean] :skip_working (false) If true, skips counting running jobs.
      # @option options [Integer, nil] :max_scheduled (nil) Max number of scheduled jobs to consider; nil for no limit.
      # @return [Integer] Total job queue size.
      # @example Calculate size across all queues
      #   HireFire::Macro::Sidekiq.job_queue_size
      # @example Calculate size for the "default" queue
      #   HireFire::Macro::Sidekiq.job_queue_size(:default)
      # @example Calculate size across "default" and "mailer" queues
      #   HireFire::Macro::Sidekiq.job_queue_size(:default, :mailer)
      # @example Calculate size for the "default" queue, excluding scheduled jobs
      #   HireFire::Macro::Sidekiq.job_queue_size(:default, skip_scheduled: true)
      # @example Calculate size for the "default" queue, excluding retries
      #   HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true)
      # @example Calculate size for the "default" queue, excluding running jobs
      #   HireFire::Macro::Sidekiq.job_queue_size(:default, skip_working: true)
      # @example Calculate size for the "default" queue using server-side aggregation
      #   HireFire::Macro::Sidekiq.job_queue_size(:default, server: true)
      # @example Calculate size for the "default" queue, limiting counting of scheduled jobs to 100_000
      #   HireFire::Macro::Sidekiq.job_queue_size(:default, max_scheduled: 100_000)
      def job_queue_size(*queues, **options)
        JobQueueSize.call(*queues, **options)
      end

      # @!visibility private
      module Common
        private

        def find_each_in_set(set)
          cursor = 0
          batch = 1000

          loop do
            entries = ::Sidekiq.redis do |connection|
              if Gem::Version.new(::Sidekiq::VERSION) >= Gem::Version.new("7.0.0")
                connection.zrange set.name, cursor, cursor + batch - 1, "WITHSCORES"
              else
                connection.zrange set.name, cursor, cursor + batch - 1, withscores: true
              end
            end

            break if entries.empty?

            entries.each do |entry, score|
              yield ::Sidekiq::SortedEntry.new(self, score, entry)
            end

            cursor += batch
          end
        end

        def registered_queues
          ::Sidekiq::Queue.all.map(&:name).to_set
        end
      end

      # @!visibility private
      module JobQueueLatency
        extend Common
        extend HireFire::Utility
        extend self

        def call(*queues, skip_retries: false, skip_scheduled: false)
          require "sidekiq/api"

          queues = normalize_queues(queues, allow_empty: true)
          latencies = []
          latencies << enqueued_latency(queues)
          latencies << set_latency(::Sidekiq::RetrySet.new, queues) unless skip_retries
          latencies << set_latency(::Sidekiq::ScheduledSet.new, queues) unless skip_scheduled
          latencies.max
        end

        private

        def enqueued_latency(queues)
          queues = registered_queues if queues.empty?

          oldest_jobs = ::Sidekiq.redis do |conn|
            conn.pipelined do |pipeline|
              queues.each do |queue|
                pipeline.lindex("queue:#{queue}", -1)
              end
            end
          end

          max_latencies = oldest_jobs.map do |job_payload|
            job = job_payload ? JSON.parse(job_payload) : {}
            job["enqueued_at"] ? Time.now.to_f - job["enqueued_at"] : 0.0
          end

          max_latencies.max || 0.0
        end

        def set_latency(set, queues)
          max_latency = 0.0
          now = Time.now

          find_each_in_set(set) do |job|
            if job.at > now
              break
            elsif queues.empty? || queues.include?(job.queue)
              max_latency = now - job.at
              break
            end
          end

          max_latency
        end
      end

      # @!visibility private
      module JobQueueSize
        extend Common
        extend HireFire::Utility
        extend self

        def call(*queues, server: false, **options)
          require "sidekiq/api"

          queues = normalize_queues(queues, allow_empty: true)

          if server
            server_lookup(queues, **options)
          else
            client_lookup(queues, **options)
          end
        end

        private

        def client_lookup(queues, skip_retries: false, skip_scheduled: false, skip_working: false, max_scheduled: nil)
          size = enqueued_size(queues)
          size += scheduled_size(queues, max_scheduled) unless skip_scheduled
          size += retry_size(queues) unless skip_retries
          size += working_size(queues) unless skip_working
          size
        end

        def enqueued_size(queues)
          queues = registered_queues if queues.empty?

          ::Sidekiq.redis do |conn|
            conn.pipelined do |pipeline|
              queues.each { |name| pipeline.llen("queue:#{name}") }
            end
          end.sum
        end

        def scheduled_size(queues, max = nil)
          size, now = 0, Time.now

          find_each_in_set(::Sidekiq::ScheduledSet.new) do |job|
            if job.at > now || max && size >= max
              break
            elsif queues.empty? || queues.include?(job["queue"])
              size += 1
            end
          end

          size
        end

        def retry_size(queues)
          size = 0
          now = Time.now

          find_each_in_set(::Sidekiq::RetrySet.new) do |job|
            if job.at > now
              break
            elsif queues.empty? || queues.include?(job["queue"])
              size += 1
            end
          end

          size
        end

        def working_size(queues)
          now = Time.now
          now_as_i = now.to_i

          ::Sidekiq::Workers.new.count do |key, tid, job|
            if job.is_a?(Hash) # Sidekiq < 7.2.1
              (queues.empty? || queues.include?(job["queue"])) && job["run_at"] <= now_as_i
            else # Sidekiq >= 7.2.1
              (queues.empty? || queues.include?(job.queue)) && job.run_at <= now
            end
          end
        end

        SERVER_SIDE_SCRIPT = <<~LUA
          local tonumber = tonumber
          local cjson_decode = cjson.decode

          local function enqueued_size(queues)
             local size = 0

             if next(queues) == nil then
                queues = redis.call("keys", "queue:*")

                for _, name in ipairs(queues) do
                   queues[string.sub(name, 7)] = true
                end
             end

             for queue, _ in pairs(queues) do
                size = size + redis.call("llen", "queue:" .. queue)
             end

             return size
          end

          local function set_size(queues, set, now, max)
             local size = 0
             local limit = 100
             local offset = 0
             local jobs

             repeat
                jobs = redis.call("zrangebyscore", set, "-inf", now, "LIMIT", offset, limit)
                offset = offset + limit

                for i = 1, #jobs do
                   local job = cjson_decode(jobs[i])

                   if job and (next(queues) == nil or queues[job.queue]) then
                      size = size + 1
                   end
                end
             until #jobs == 0 or (max > 0 and size >= max)

             return size
          end

          local function working_size(queues)
             local size = 0
             local cursor = "0"

             repeat
                local process_sets = redis.call("SSCAN", "processes", cursor)
                cursor = process_sets[1]

                for _, process_key in ipairs(process_sets[2]) do
                   local worker_key = process_key .. ":work"
                   local worker_data = redis.call("HGETALL", worker_key)

                   for i = 2, #worker_data, 2 do
                      local worker = cjson_decode(worker_data[i])

                      if next(queues) == nil or queues[worker.queue] then
                         size = size + 1
                      end
                   end
                end
             until cursor == "0"

             return size
          end

          local now            = tonumber(ARGV[1])
          local max_scheduled  = tonumber(ARGV[2])
          local skip_scheduled = tonumber(ARGV[3]) == 1
          local skip_retries   = tonumber(ARGV[4]) == 1
          local skip_working   = tonumber(ARGV[5]) == 1

          local queues = {}
          for i = 6, #ARGV do
             queues[ARGV[i]] = true
          end

          local size = enqueued_size(queues)

          if not skip_scheduled then
             size = size + set_size(queues, "schedule", now, max_scheduled)
          end

          if not skip_retries then
             size = size + set_size(queues, "retry", now, 0)
          end

          if not skip_working then
             size = size + working_size(queues)
          end

          return size
        LUA

        SERVER_SIDE_SCRIPT_SHA = Digest::SHA1.hexdigest(SERVER_SIDE_SCRIPT).freeze

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
