# frozen_string_literal: true

require "digest/sha1"

module HireFire
  module Macro
    module Sidekiq
      extend self

      # The latency in seconds for the provided queue.
      #
      # @example Sidekiq Queue Latency Macro Usage
      #   HireFire::Macro::Sidekiq.queue # default queue
      #   HireFire::Macro::Sidekiq.queue("email") # email queue
      #
      def latency(queue = "default")
        ::Sidekiq::Queue.new(queue).latency
      end

      # Counts the amount of jobs in the (provided) Sidekiq queue(s).
      #
      # @example Sidekiq Queue Size Macro Usage
      #   HireFire::Macro::Sidekiq.queue # all queues
      #   HireFire::Macro::Sidekiq.queue("email") # only email queue
      #   HireFire::Macro::Sidekiq.queue("audio", "video") # audio and video queues
      #   HireFire::Macro::Sidekiq.queue("email", skip_scheduled: true) # only email, will not count scheduled queue
      #   HireFire::Macro::Sidekiq.queue("audio", skip_retries: true) # only audio, will not count the retries queue
      #   HireFire::Macro::Sidekiq.queue("audio", skip_working: true) # only audio, will not count already queued
      #   HireFire::Macro::Sidekiq.queue("audio", server: true) # Executes the count on the server side using Lua
      #
      # @param [Array] queues provide one or more queue names, or none for "all".
      # @return [Integer] the number of jobs in the queue(s).
      #
      def queue(*queues)
        require "sidekiq/api"

        queues.flatten!

        options = if queues.last.is_a?(Hash)
          queues.pop
        else
          {}
        end

        queues.map!(&:to_s)
        all_queues = ::Sidekiq::Queue.all.map(&:name)
        queues = all_queues if queues.empty?

        if options[:server]
          count_server_side(queues, options)
        elsif fast_lookup_capable?(queues, all_queues)
          fast_lookup(options)
        else
          dynamic_lookup(queues, options)
        end
      end

      private

      def fast_lookup_capable?(queues, all_queues)
        # When no queue names are provided (or all of them are), we know we
        # can peform much faster counts using Sidekiq::Stats and Redis
        queues.sort == all_queues.sort
      end

      def fast_lookup(options)
        stats = ::Sidekiq::Stats.new

        in_queues = stats.enqueued

        if !options[:skip_scheduled]
          in_schedule = ::Sidekiq.redis { |c| c.zcount("schedule", "-inf", Time.now.to_f) }
        end

        if !options[:skip_retries]
          in_retry = ::Sidekiq.redis { |c| c.zcount("retry", "-inf", Time.now.to_f) }
        end

        if !options[:skip_working]
          in_progress = stats.workers_size
        end

        [in_queues, in_schedule, in_retry, in_progress].compact.inject(&:+)
      end

      def dynamic_lookup(queues, options)
        in_queues = queues.inject(0) do |memo, name|
          memo += ::Sidekiq::Queue.new(name).size
          memo
        end

        if !options[:skip_scheduled]
          max = options[:max_scheduled]

          # For potentially long-running loops, compare all jobs against
          # time when the set snapshot was taken to avoid incorrect counts.
          now = Time.now

          in_schedule = ::Sidekiq::ScheduledSet.new.inject(0) do |memo, job|
            memo += 1 if queues.include?(job["queue"]) && job.at <= now
            break memo if max && memo >= max
            memo
          end
        end

        if !options[:skip_retries]
          now = Time.now

          in_retry = ::Sidekiq::RetrySet.new.inject(0) do |memo, job|
            memo += 1 if queues.include?(job["queue"]) && job.at <= now
            memo
          end
        end

        now = Time.now.to_i

        if !options[:skip_working]
          # Objects yielded to Workers#each:
          # https://github.com/mperham/sidekiq/blob/305ab8eedc362325da2e218b2a0e20e510668a42/lib/sidekiq/api.rb#L912
          in_progress = ::Sidekiq::Workers.new.count do |key, tid, job|
            queues.include?(job["queue"]) && job["run_at"] <= now
          end
        end

        [in_queues, in_schedule, in_retry, in_progress].compact.inject(&:+)
      end

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
        local function count_in_sorted_set(queues, key, run_at, max)
            local count = 0
            local max_count = 0
            local cursor = '0'

            repeat
                if max > 0 and max_count >= max then
                    return count
                end

                local response = redis.call('zscan', key, cursor)
                cursor = response[1]
                local elements = response[2]

                for i = 1, #elements, 2 do
                    if max > 0 and max_count >= max then
                        return count
                    end

                    max_count = max_count + 1

                    local job_data = elements[i]
                    local job_run_at = tonumber(elements[i + 1])
                    local job = cjson.decode(job_data)

                    if job and queues[job.queue] and job_run_at <= run_at then
                       count = count + 1
                    end
                end
            until cursor == '0'

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

      def count_server_side(queues, options)
        ::Sidekiq.redis do |conn|
          now = Time.now.to_i
          max_scheduled = options[:max_scheduled] || 0
          skip_scheduled = options[:skip_scheduled] ? 1 : 0
          skip_retries = options[:skip_retries] ? 1 : 0
          skip_working = options[:skip_working] ? 1 : 0

          if defined?(::Sidekiq::RedisClientAdapter::CompatClient) && conn.is_a?(::Sidekiq::RedisClientAdapter::CompatClient)
            count_with_redis_client(conn, now, max_scheduled, skip_scheduled, skip_retries, skip_working, *queues)
          elsif defined?(::Redis) && conn.is_a?(::Redis)
            count_with_redis(conn, now, max_scheduled, skip_scheduled, skip_retries, skip_working, *queues)
          else
            raise "Unsupported Redis connection type: #{conn.class}"
          end
        end
      end

      def count_with_redis(conn, *args)
        conn.evalsha(SERVER_SIDE_SCRIPT_SHA, argv: args)
      rescue Redis::CommandError => e
        if e.message.include?("NOSCRIPT")
          conn.script(:load, SERVER_SIDE_SCRIPT)
          retry
        else
          raise
        end
      end

      def count_with_redis_client(conn, *args)
        conn.call("evalsha", SERVER_SIDE_SCRIPT_SHA, 0, *args)
      rescue RedisClient::CommandError => e
        if e.message.include?("NOSCRIPT")
          conn.call("script", "load", SERVER_SIDE_SCRIPT)
          retry
        else
          raise
        end
      end
    end
  end
end
