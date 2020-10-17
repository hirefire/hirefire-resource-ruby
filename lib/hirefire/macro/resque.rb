# frozen_string_literal: true

module HireFire
  module Macro
    module Resque
      extend self

      # Counts the amount of jobs in the (provided) Resque queue(s).
      #
      # @example Resque Macro Usage
      #   HireFire::Macro::Resque.queue # all queues
      #   HireFire::Macro::Resque.queue("email") # only email queue
      #   HireFire::Macro::Resque.queue("audio", "video") # audio and video queues
      #
      # @param [Array] queues provide one or more queue names, or none for "all".
      # @return [Integer] the number of jobs in the queue(s).
      #
      def queue(*queues)
        queues = queues.flatten.map(&:to_s)
        queues = ::Resque.queues if queues.empty?

        return 0 if queues.empty?

        redis = ::Resque.redis
        ids = Array(redis.smembers(:workers)).compact
        raw_jobs = redis.pipelined { ids.map { |id| redis.get("worker:#{id}") } }
        jobs = raw_jobs.map { |raw_job| ::Resque.decode(raw_job) || {} }

        in_queues = redis.pipelined do
          queues.map { |queue| redis.llen("queue:#{queue}") }
        end.map(&:to_i).inject(&:+)

        in_progress = jobs.inject(0) do |memo, job|
          memo += 1 if queues.include?(job["queue"])
          memo
        end

        in_queues + in_progress
      end
    end
  end
end
