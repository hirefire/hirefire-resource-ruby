# frozen_string_literal: true

require_relative "../plan/hooks"
require_relative "../plan/size_only"
require_relative "deprecated/resque"

module HireFire
  module Macro
    module Resque
      extend HireFire::Macro::Deprecated::Resque
      extend HireFire::Utility
      extend HireFire::Plan::Hooks
      extend HireFire::Plan::SizeOnly
      extend HireFire::Errors::JobQueueLatencyUnsupported
      extend self

      SIZE_METHODS = [
        :enqueued_size,
        :scheduled_size
      ].freeze

      def job_queue_size(*queues)
        queues = normalize_queues(queues, allow_empty: true)

        SIZE_METHODS.sum do |size_method|
          method(size_method).call(queues)
        end
      end

      private

      def enqueued_size(queues)
        queues = registered_queues if queues.empty?

        ::Resque.redis.pipelined do |pipeline|
          queues.each do |queue|
            pipeline.llen("queue:#{queue}")
          end
        end.sum
      end

      def scheduled_size(queues)
        batch = 1000
        total_size = 0
        current_time = Time.now.to_i
        min_score = "-inf"

        loop do
          timestamps = ::Resque.redis.zrangebyscore(
            "delayed_queue_schedule",
            min_score,
            current_time,
            limit: [0, batch]
          )

          break if timestamps.empty?

          if queues.empty?
            total_size += ::Resque.redis.pipelined do |pipeline|
              timestamps.each do |timestamp|
                pipeline.llen("delayed:#{timestamp}")
              end
            end.sum
          else
            timestamps.each do |timestamp|
              job_cursor = 0

              loop do
                encoded_jobs = ::Resque.redis.lrange(
                  "delayed:#{timestamp}",
                  job_cursor,
                  job_cursor + batch - 1
                )

                break if encoded_jobs.empty?

                total_size += encoded_jobs.count do |encoded_job|
                  queue = delayed_job_queue(encoded_job)
                  queue && queues.include?(queue)
                end

                break if encoded_jobs.size < batch

                job_cursor += batch
              end
            end
          end

          break if timestamps.size < batch

          min_score = "(#{timestamps.last}"
        end

        total_size
      end

      def delayed_job_queue(encoded_job)
        payload = ::Resque.decode(encoded_job)
        return unless payload.is_a?(Hash)

        queue = payload["queue"]
        return if queue.nil? || queue == ""

        queue
      rescue ::Resque::Helpers::DecodeException, TypeError
        nil
      end

      def registered_queues
        ::Resque.queues.to_set
      end
    end
  end
end
