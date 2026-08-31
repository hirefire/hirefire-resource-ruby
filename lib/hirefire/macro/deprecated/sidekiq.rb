# frozen_string_literal: true

module HireFire
  module Macro
    module Deprecated
      module Sidekiq
        def latency(queue = "default")
          ::Sidekiq::Queue.new(queue.to_s).latency
        end

        def queue(*args)
          require "sidekiq/api"

          args.flatten!

          options = args.last.is_a?(Hash) ? args.pop : {}
          options[:skip_working] = true if options.key?(:skip_working) && options[:skip_working].nil?
          queues = args.map(&:to_s)
          all_queues = ::Sidekiq::Queue.all.map(&:name)
          queues = all_queues if queues.empty?

          if fast_lookup_capable?(queues, all_queues, options)
            fast_lookup(options)
          else
            dynamic_lookup(queues, options)
          end
        end

        private

        def fast_lookup_capable?(queues, all_queues, options)
          return false unless options.fetch(:skip_working, true)

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

          if !options.fetch(:skip_working, true)
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

          now = Time.now
          now_as_i = now.to_i

          if !options.fetch(:skip_working, true)
            in_progress = ::Sidekiq::Workers.new.count do |key, tid, job|
              if job.is_a?(Hash)
                queues.include?(job["queue"]) && job["run_at"] <= now_as_i
              else
                queues.include?(job.queue) && job.run_at <= now
              end
            end
          end

          [in_queues, in_schedule, in_retry, in_progress].compact.inject(&:+)
        end
      end
    end
  end
end
