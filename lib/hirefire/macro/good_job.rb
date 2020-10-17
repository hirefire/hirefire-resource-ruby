module HireFire
  module Macro
    module GoodJob
      extend self

      # Queries the PostgreSQL database through GoodJob in order to
      # count the amount of jobs in the specified queue.
      #
      # @example Queue Macro Usage
      #   HireFire::Macro::GoodJob.queue # counts all queues.
      #   HireFire::Macro::GoodJob.queue("email") # counts the `email` queue.
      #
      # @param [String] queue the queue name to count. (default: nil # gets all queues)
      # @return [Integer] the number of jobs in the queue(s).
      #
      def queue(*queues)
        scope = ::GoodJob::Job.only_scheduled.unfinished
        scope = scope.where(queue_name: queues) if queues.any?
        scope.count
      end
    end
  end
end
