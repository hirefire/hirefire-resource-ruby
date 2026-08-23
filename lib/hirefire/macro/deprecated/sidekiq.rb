# frozen_string_literal: true

module HireFire
  module Macro
    module Deprecated
      # Provides backward compatibility with the deprecated Sidekiq macro.
      # For new implementations, refer to {HireFire::Macro::Sidekiq}.
      module Sidekiq
        # Calculates the latency (in seconds) for the specified Sidekiq queue.
        #
        # The method uses the Sidekiq::Queue class to obtain the latency of a queue, which
        # is the duration since the oldest job in the queue was enqueued.
        #
        # @param queue [String, Symbol] The name of the queue to measure latency.
        #   Defaults to "default" if no queue name is provided.
        # @return [Float] The latency of the queue in seconds.
        # @example Calculating latency for the default queue
        #   HireFire::Macro::Sidekiq.latency
        # @example Calculating latency for the "critical" queue
        #   HireFire::Macro::Sidekiq.latency("critical")
        def latency(queue = "default")
          ::Sidekiq::Queue.new(queue.to_s).latency
        end

        # Counts jobs in the specified Sidekiq queue(s).
        #
        # By default counts the waiting set (live + due scheduled + due retry),
        # matching {HireFire::Macro::Sidekiq.job_queue_size}. Pass
        # +skip_working: false+ to include in-flight work.
        #
        # @param args [Array<String, Symbol, Hash>] Queue names to count jobs in and an optional hash of options.
        #   Pass an empty array or no arguments to count jobs in all queues.
        #   The last argument can be a Hash of options to modify the count behavior.
        #   Possible keys are :skip_scheduled, :skip_retries (booleans, default false),
        #   :skip_working (boolean, default true: exclude in-progress; pass false to include),
        #   and :max_scheduled (Integer, caps how many scheduled jobs are counted, applied
        #   only when specific queue names are given).
        # @return [Integer] Waiting-set size by default. With +skip_working: false+, also includes in-progress.
        # @example Counting jobs in all queues
        #   HireFire::Macro::Sidekiq.queue
        # @example Counting jobs in the "default" and "critical" queues
        #   HireFire::Macro::Sidekiq.queue("default", "critical")
        # @example Counting jobs in the "default" queue, excluding scheduled jobs
        #   HireFire::Macro::Sidekiq.queue("default", skip_scheduled: true)
        # @example Counting jobs in the "default" queue, excluding retryable jobs
        #   HireFire::Macro::Sidekiq.queue("default", skip_retries: true)
        # @example Counting jobs in the "default" queue, including in-progress jobs
        #   HireFire::Macro::Sidekiq.queue("default", skip_working: false)
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
