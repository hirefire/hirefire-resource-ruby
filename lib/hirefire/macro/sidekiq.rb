# frozen_string_literal: true

require "digest/sha1"
require_relative "../plan/hooks"
require_relative "../utility"
require_relative "deprecated/sidekiq"
require_relative "sidekiq/due_cache"

module HireFire
  module Macro
    module Sidekiq
      extend HireFire::Macro::Deprecated::Sidekiq
      extend HireFire::Plan::Hooks
      extend self

      PLAN_OPTION_SCHEMA = {
        Strategy::JQL => {
          "skip_retries" => :boolean,
          "skip_scheduled" => :boolean
        }.freeze,
        Strategy::JQS => {
          "skip_retries" => :boolean,
          "skip_scheduled" => :boolean,
          "skip_working" => :boolean,
          "max_scheduled" => :non_negative_integer,
          "server" => :boolean
        }.freeze
      }.freeze

      def library_loaded?
        !!defined?(::Sidekiq)
      end

      def plan_options(strategy, options)
        extract_plan_options(strategy, options, PLAN_OPTION_SCHEMA)
      end

      def before_sample_job_queues
        DueCache.begin_sample!
      end

      def after_sample_job_queues(token = nil)
        DueCache.end_sample!(token)
      end

      def reinit_after_fork
        DueCache.reinit_after_fork
      end

      def job_queue_latency(*queues, **options)
        JobQueueLatency.call(*queues, **options)
      end

      def job_queue_size(*queues, **options)
        JobQueueSize.call(*queues, **options)
      end

      def job_queue_working(*queues)
        JobQueueWorking.call(*queues)
      end

      module Common
        private

        def registered_queues
          ::Sidekiq::Queue.all.map(&:name).to_set
        end

        def working_size(queues)
          return ::Sidekiq::Workers.new.size if queues.empty?

          now = Time.now
          now_as_i = now.to_i

          DueCache.working_jobs.count do |job|
            if job.is_a?(Hash)
              queues.include?(job["queue"]) && job["run_at"] <= now_as_i
            else
              queues.include?(job.queue) && job.run_at <= now
            end
          end
        end
      end

      module JobQueueWorking
        extend Common
        extend HireFire::Macro::Utility
        extend self

        def call(*queues)
          require "sidekiq/api"

          queues = normalize_queues(queues, allow_empty: true)
          working_size(queues)
        end
      end

      module JobQueueLatency
        extend Common
        extend HireFire::Macro::Utility
        extend self

        def call(*queues, skip_retries: false, skip_scheduled: false)
          require "sidekiq/api"

          queues = normalize_queues(queues, allow_empty: true)
          latencies = []
          latencies << enqueued_latency(queues)
          latencies << DueCache.latency("retry", queues) unless skip_retries
          latencies << DueCache.latency("schedule", queues) unless skip_scheduled
          latencies.max.to_f
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

          max_latencies.max.to_f
        end

        def parse_live_job(job_payload)
          job = JSON.parse(job_payload)
          job.is_a?(Hash) ? job : {}
        rescue JSON::ParserError, TypeError
          {}
        end

        def job_enqueued_latency(job)
          timestamp = job["enqueued_at"] || job["created_at"]
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
      end

      module JobQueueSize
        extend Common
        extend HireFire::Macro::Utility
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

          local function set_size(queues, set, now, max, budget)
             local size = 0
             local walked = 0
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

                   if walked >= budget then
                      size = size + redis.call("zcount", set, "-inf", ARGV[1]) - walked

                      if max >= 0 and size > max then
                         return max
                      end

                      return size
                   end

                   walked = walked + 1

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
          local budget         = tonumber(ARGV[6])

          local queues = {}
          for i = 7, #ARGV do
             queues[ARGV[i]] = true
          end

          local size = enqueued_size(queues)

          if not skip_scheduled then
             size = size + set_size(queues, "schedule", now, max_scheduled, budget)
          end

          if not skip_retries then
             size = size + set_size(queues, "retry", now, -1, budget)
          end

          if not skip_working then
             size = size + working_size(queues, now)
          end

          return size
        LUA

        SERVER_SIDE_SCRIPT_SHA = Digest::SHA1.hexdigest(SERVER_SIDE_SCRIPT).freeze
        SERVER_WALK_MEMBER_BUDGET = 10_000

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
          DueCache.size("schedule", queues, max_scheduled: max)
        end

        def retry_size(queues)
          DueCache.size("retry", queues)
        end

        def server_lookup(queues, skip_scheduled: false, skip_retries: false, skip_working: false, max_scheduled: nil)
          max_scheduled = max_scheduled.nil? ? -1 : [max_scheduled.to_i, 0].max
          flags = [skip_scheduled, skip_retries, skip_working].map { |skip| skip ? 1 : 0 }
          arguments = [Time.now.to_f, max_scheduled, *flags, SERVER_WALK_MEMBER_BUDGET, *queues]

          ::Sidekiq.redis do |connection|
            connection.call("evalsha", SERVER_SIDE_SCRIPT_SHA, 0, *arguments)
          rescue RedisClient::CommandError => e
            raise unless e.message.include?("NOSCRIPT")

            connection.call("eval", SERVER_SIDE_SCRIPT, 0, *arguments)
          end
        end
      end
    end
  end
end
