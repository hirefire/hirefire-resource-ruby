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

        queues = queues.map(&:to_s)
        queues = ::Sidekiq::Stats.new.queues.map { |name, _| name } if queues.empty?

        in_queues = queues.inject(0) do |memo, name|
          memo += ::Sidekiq::Queue.new(name).size
          memo
        end

        if !options[:skip_scheduled]
          max = options[:max_scheduled]
          in_schedule = ::Sidekiq::ScheduledSet.new.inject(0) do |memo, job|
            memo += 1 if queues.include?(job["queue"]) && job.at <= Time.now
            break memo if max && memo >= max
            memo
          end
        end

        if !options[:skip_retries]
          in_retry = ::Sidekiq::RetrySet.new.inject(0) do |memo, job|
            memo += 1 if queues.include?(job["queue"]) && job.at <= Time.now
            memo
          end
        end

        i = ::Sidekiq::VERSION >= "3.0.0" ? 2 : 1
        in_progress = ::Sidekiq::Workers.new.inject(0) do |memo, job|
          memo += 1 if queues.include?(job[i]["queue"]) && job[i]["run_at"] <= Time.now.to_i
          memo
        end

        [in_queues, in_schedule, in_retry, in_progress].compact.inject(&:+)
      end
    end
  end
end

