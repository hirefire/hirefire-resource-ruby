# encoding: utf-8

module HireFire
  module Macro
    module Que
      extend self

      # Queries the PostgreSQL database through Que in order to
      # count the amount of jobs in the specified queue.
      #
      # @example Queue Macro Usage
      #   HireFire::Macro::Que.queue # counts all queues.
      #   HireFire::Macro::Que.queue("email") # counts the `email` queue.
      #
      # @param [String] queue the queue name to count. (default: nil # gets all queues)
      # @return [Integer] the number of jobs in the queue(s).
      #
      def queue(queue = nil)
        query = ::Que::Web::SQL[:dashboard_stats]
        query = "#{query} WHERE queue = '#{queue}'" if queue
        results = ::Que.execute(query).first
        results["total"].to_i - results["failing"].to_i
      end
    end
  end
end
