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
      #
      # @return [Integer] the number of jobs in the queue(s).
      def queue(*queues)
        queues = ::Sidekiq.redis { |conn| conn.smembers("queues") } if queues.empty?
        queues.
          flatten.
          inject(0) { |memo, queue|
            memo += ::Sidekiq.redis do |conn|
              conn.llen("queue:#{queue}")
            end
            memo
          }
      end
    end
  end
end

