# frozen_string_literal: true

require "digest/sha1"
require_relative "../plan/hooks"
require_relative "deprecated/sidekiq"
require_relative "sidekiq/due_cache"

module HireFire
  module Macro
    module Sidekiq
      extend HireFire::Macro::Deprecated::Sidekiq
      extend HireFire::Plan::Hooks
      extend self

      PLAN_OPTION_SCHEMA = {
        "jql" => {
          "skip_retries" => :boolean,
          "skip_scheduled" => :boolean
        }.freeze,
        "jqs" => {
          "skip_retries" => :boolean,
          "skip_scheduled" => :boolean,
          "skip_working" => :boolean,
          "max_scheduled" => :non_negative_integer,
          "server" => :boolean
        }.freeze
      }.freeze

      # Filter and coerce lease-plan +options+ for Sidekiq sampling.
      #
      # @param strategy [String] +"jql"+ or +"jqs"+
      # @param options [Object] raw plan options (Hash or ignored)
      # @return [Hash]
      def plan_options(strategy, options)
        extract_plan_options(strategy, options, PLAN_OPTION_SCHEMA)
      end

      # Open DueCache for one Dispatcher sample wave (all plan + dyno Sidekiq macros).
      # No-op when the Sidekiq gem is not loaded.
      #
      # @return [Integer, nil] wave token for {#after_sample_job_queues}
      def before_sample_job_queues
        return nil unless defined?(::Sidekiq)

        DueCache.begin_sample!
      end

      # Close DueCache for the wave token from {#before_sample_job_queues}.
      #
      # @param token [Integer, nil]
      # @return [void]
      def after_sample_job_queues(token = nil)
        return unless defined?(::Sidekiq)

        DueCache.end_sample!(token)
      end

      # Reset DueCache after fork / abandoned inherited state.
      #
      # @return [void]
      def reinit_after_fork
        DueCache.reinit_after_fork
      end

      # Calculates the maximum job queue latency using Sidekiq. If no queues are specified, it
      # measures latency across all available queues.
      #
      # Client schedule/retry due walks share a process-local rank cache scoped to one
      # Dispatcher sample wave so many named samplers amortize one ascending walk per set.
      # Outside a sample wave (console or one-off), each call walks cold. Empty queue list
      # (all queues) uses a cheap first-score due read and never walks/decodes due members.
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
      # Client schedule/retry due walks share a process-local rank cache scoped to one Dispatcher
      # sample wave. Outside a sample wave (console or one-off), each call walks cold. Due counts
      # are served only after the due region is complete for that fill (except a call-local
      # +max_scheduled+ walk budget on named queues). Empty queue list (all queues) uses +ZCOUNT+
      # for due size and never walks/decodes due members (+max_scheduled+ is ignored there).
      # +server: true+ uses Lua and does not read or write the cache.
      #
      # @param queues [Array<String, Symbol>] (optional) Names of the queues for size measurement.
      #   If not provided, size is measured across all queues.
      # @param options [Hash] Options to control and filter the count.
      # @option options [Boolean] :server (false) If true, counts jobs server-side using Lua scripting.
      # @option options [Boolean] :skip_retries (false) If true, skips counting jobs in retry queues.
      # @option options [Boolean] :skip_scheduled (false) If true, skips counting jobs in scheduled queues.
      # @option options [Boolean] :skip_working (true) If true (default), skips counting running jobs.
      #   Pass +false+ to include in-flight work (kept through 2.0).
      # @option options [Integer, nil] :max_scheduled (nil) Walk budget for schedule dues on named-queue
      #   client walks and on +server: true+. Ignored for client all-queues (+ZCOUNT+). nil means no limit.
      # @return [Integer] Total job queue size (waiting set: live + due scheduled + due retry by default).
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
      # @example Calculate size for the "default" queue, including running jobs
      #   HireFire::Macro::Sidekiq.job_queue_size(:default, skip_working: false)
      # @example Calculate size for the "default" queue using server-side aggregation
      #   HireFire::Macro::Sidekiq.job_queue_size(:default, server: true)
      # @example Cap named schedule walk at 100_000 dues
      #   HireFire::Macro::Sidekiq.job_queue_size(:default, max_scheduled: 100_000)
      def job_queue_size(*queues, **options)
        JobQueueSize.call(*queues, **options)
      end

      # Counts in-flight (working) jobs for the requested queues. Empty queue list
      # means all queues. Uses Sidekiq WorkSet / process work hashes (same filter as
      # +job_queue_size(..., skip_working: false)+ working contribution). Never folded
      # into JQL/JQS waiting samples. Plan path records this under nested strategy +wrk+.
      #
      # @param queues [Array<String, Symbol>] (optional) Queue names. Empty = all.
      # @return [Integer] In-flight job count (run_at ≤ now).
      # @example All queues
      #   HireFire::Macro::Sidekiq.job_queue_working
      # @example Named queues only
      #   HireFire::Macro::Sidekiq.job_queue_working(:default, :mailer)
      def job_queue_working(*queues)
        JobQueueWorking.call(*queues)
      end

      # @!visibility private
      module Common
        private

        def registered_queues
          ::Sidekiq::Queue.all.map(&:name).to_set
        end

        def working_size(queues)
          now = Time.now
          now_as_i = now.to_i

          ::Sidekiq::Workers.new.count do |key, tid, job|
            if job.is_a?(Hash)
              (queues.empty? || queues.include?(job["queue"])) && job["run_at"] <= now_as_i
            else
              (queues.empty? || queues.include?(job.queue)) && job.run_at <= now
            end
          end
        end
      end

      # @!visibility private
      module JobQueueWorking
        extend Common
        extend HireFire::Utility
        extend self

        def call(*queues)
          require "sidekiq/api"

          queues = normalize_queues(queues, allow_empty: true)
          working_size(queues)
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
            job_enqueued_latency(parse_live_job(job_payload))
          end

          (max_latencies.max || 0.0).to_f
        end

        def parse_live_job(job_payload)
          return {} if job_payload.nil? || job_payload == ""

          job = JSON.parse(job_payload)
          job.is_a?(Hash) ? job : {}
        rescue JSON::ParserError, TypeError
          {}
        end

        def job_enqueued_latency(job)
          timestamp = job["enqueued_at"] || job["created_at"]
          return 0.0 unless timestamp

          epoch =
            case timestamp
            when Float
              return 0.0 unless timestamp.finite?
              timestamp
            when Integer
              timestamp / 1000.0
            else
              return 0.0
            end

          [Time.now.to_f - epoch, 0.0].max
        end

        def set_latency(set, queues)
          DueCache.latency(set.name, queues)
        end
      end

      # @!visibility private
      module JobQueueSize
        extend Common
        extend HireFire::Utility
        extend self

        SERVER_SIDE_SCRIPT = <<~LUA
          local tonumber = tonumber
          local cjson_decode = cjson.decode

          local function enqueued_size(queues)
             local size = 0
             local names = queues

             if next(queues) == nil then
                names = {}
                local registered = redis.call("smembers", "queues")

                for _, name in ipairs(registered) do
                   names[name] = true
                end
             end

             for queue, _ in pairs(names) do
                size = size + redis.call("llen", "queue:" .. queue)
             end

             return size
          end

          local function set_size(queues, set, now, max)
             local size = 0
             local limit = 1000
             local cursor = 0
             local jobs

             repeat
                jobs = redis.call("zrange", set, cursor, cursor + limit - 1, "WITHSCORES")
                cursor = cursor + limit

                for i = 1, #jobs, 2 do
                   if max >= 0 and size >= max then
                      return size
                   end

                   if tonumber(jobs[i + 1]) > now then
                      return size
                   end

                   local ok, job = pcall(cjson_decode, jobs[i])

                   if ok and job and (next(queues) == nil or queues[job.queue]) then
                      size = size + 1
                   end
                end
             until #jobs == 0

             return size
          end

          local function working_size(queues, now)
             local size = 0
             local cursor = "0"

             repeat
                local process_sets = redis.call("SSCAN", "processes", cursor)
                cursor = process_sets[1]

                for _, process_key in ipairs(process_sets[2]) do
                   local worker_key = process_key .. ":work"
                   local worker_data = redis.call("HGETALL", worker_key)

                   for i = 2, #worker_data, 2 do
                      local ok, worker = pcall(cjson_decode, worker_data[i])

                      if ok and worker and (next(queues) == nil or queues[worker.queue])
                         and tonumber(worker.run_at or 0) <= now then
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
             size = size + set_size(queues, "retry", now, -1)
          end

          if not skip_working then
             size = size + working_size(queues, now)
          end

          return size
        LUA

        SERVER_SIDE_SCRIPT_SHA = Digest::SHA1.hexdigest(SERVER_SIDE_SCRIPT).freeze

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

        def client_lookup(queues, skip_retries: false, skip_scheduled: false, skip_working: true, max_scheduled: nil)
          skip_working = true if skip_working.nil?
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
          DueCache.size("schedule", queues, max_scheduled: max)
        end

        def retry_size(queues)
          DueCache.size("retry", queues)
        end

        def server_lookup(queues, skip_scheduled: false, skip_retries: false, skip_working: true, max_scheduled: nil)
          skip_working = true if skip_working.nil?
          max_scheduled = max_scheduled.nil? ? -1 : [max_scheduled.to_i, 0].max
          ::Sidekiq.redis do |connection|
            now = Time.now.to_f
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
