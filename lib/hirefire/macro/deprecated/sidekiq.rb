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

        # Counts the number of jobs in the specified Sidekiq queue(s).
        #
        # The method supports various options to include or exclude jobs from
        # specific sets like scheduled, retries, or in-progress jobs.
        #
        # @param args [Array<String, Symbol, Hash>] Queue names to count jobs in and an optional hash of options.
        #   Pass an empty array or no arguments to count jobs in all queues.
        #   The last argument can be a Hash of options to modify the count behavior.
        #   Possible keys are :skip_scheduled, :skip_retries, :skip_working.
        #   These keys are booleans which default to false.
        # @return [Integer] Total number of jobs in the specified queues.
        # @example Counting jobs in all queues
        #   HireFire::Macro::Sidekiq.queue
        # @example Counting jobs in the "default" and "critical" queues
        #   HireFire::Macro::Sidekiq.queue("default", "critical")
        # @example Counting jobs in the "default" queue, excluding scheduled jobs
        #   HireFire::Macro::Sidekiq.queue("default", skip_scheduled: true)
        # @example Counting jobs in the "default" queue, excluding retryable jobs
        #   HireFire::Macro::Sidekiq.queue("default", skip_retries: true)
        # @example Counting jobs in the "default" queue, excluding in-progress jobs
        #   HireFire::Macro::Sidekiq.queue("default", skip_working: true)
        def queue(*args)
          require "sidekiq/api"

          args.flatten!

          options = args.last.is_a?(Hash) ? args.pop : {}
          queues = args.map(&:to_s)
          all_queues = ::Sidekiq::Queue.all.map(&:name)
          queues = all_queues if queues.empty?

          if fast_lookup_capable?(queues, all_queues)
            fast_lookup(options)
          else
            dynamic_lookup(queues, options)
          end
        end

        private

        def fast_lookup_capable?(queues, all_queues)
          # When no queue names are provided (or all of them are), we know we
          # can perform much faster counts using Sidekiq::Stats and Redis
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

          now = Time.now
          now_as_i = now.to_i

          if !options[:skip_working]
            in_progress = ::Sidekiq::Workers.new.count do |key, tid, job|
              if job.is_a?(Hash) # Sidekiq < 7.2.1
                queues.include?(job["queue"]) && job["run_at"] <= now_as_i
              else # Sidekiq >= 7.2.1
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
