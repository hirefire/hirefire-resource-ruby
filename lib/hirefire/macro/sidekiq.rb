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
      #
      # @param [Array] queues provide one or more queue names, or none for "all".
      # @return [Integer] the number of jobs in the queue(s).
      #
      def queue(*queues)
        require "sidekiq/api"

        queues = queues.flatten.map(&:to_s)
        queues = ::Sidekiq::Stats.new.queues.map { |name, _| name } if queues.empty?

        in_queues = queues.inject(0) do |memo, name|
          memo += ::Sidekiq::Queue.new(name).size
          memo
        end

        in_schedule = ::Sidekiq::ScheduledSet.new.inject(0) do |memo, job|
          memo += 1 if queues.include?(job["queue"]) && job.at <= Time.now
          memo
        end

        in_retry = ::Sidekiq::RetrySet.new.inject(0) do |memo, job|
          memo += 1 if queues.include?(job["queue"]) && job.at <= Time.now
          memo
        end

        in_progress = ::Sidekiq::Workers.new.inject(0) do |memo, job|
          memo += 1 if queues.include?(job[1]["queue"]) && job[1]["run_at"] <= Time.now.to_i
          memo
        end

        in_queues + in_schedule + in_retry + in_progress
      end
    end
  end
end

