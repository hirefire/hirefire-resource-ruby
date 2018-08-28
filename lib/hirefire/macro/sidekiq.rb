# encoding: utf-8

module HireFire
  module Macro
    module Sidekiq
      extend self

      # Counts the amount of jobs in the (provided) Sidekiq queue(s).
      #
      # @example Sidekiq Macro Usage
      #   HireFire::Macro::Sidekiq.queue # all queues
      #   HireFire::Macro::Sidekiq.queue("email") # only email queue
      #   HireFire::Macro::Sidekiq.queue("audio", "video") # audio and video queues
      #   HireFire::Macro::Sidekiq.queue("email", skip_scheduled: true) # only email, will not count scheduled queue
      #   HireFire::Macro::Sidekiq.queue("audio", skip_retries: true) # only audio, will not count the retries queue
      #
      # @param [Array] queues provide one or more queue names, or none for "all".
      # @return [Integer] the number of jobs in the queue(s).
      #
      def queue(*queues)
        require "sidekiq/api"

        queues.flatten!

        if queues.last.is_a?(Hash)
          options = queues.pop
        else
          options = {}
        end

        queues.map!(&:to_s)
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
        # can peform much faster counts using Sidekiq::Stats and Redis
        queues.sort == all_queues.sort
      end

      def fast_lookup(options)
        stats = ::Sidekiq::Stats.new

        in_queues = stats.enqueued

        if !options[:skip_scheduled]
          in_schedule = ::Sidekiq.redis { |c| c.zcount('schedule', '-inf', Time.now.to_f) }
        end

        if !options[:skip_retries]
          in_retry = ::Sidekiq.redis { |c| c.zcount('retry', '-inf', Time.now.to_f) }
        end

        in_progress = stats.workers_size

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

        # Objects yielded to Workers#each:
        # https://github.com/mperham/sidekiq/blob/305ab8eedc362325da2e218b2a0e20e510668a42/lib/sidekiq/api.rb#L912
        in_progress = ::Sidekiq::Workers.new.select do |key, tid, job|
          queues.include?(job['queue']) && job['run_at'] <= now
        end.size

        [in_queues, in_schedule, in_retry, in_progress].compact.inject(&:+)
      end
    end
  end
end

