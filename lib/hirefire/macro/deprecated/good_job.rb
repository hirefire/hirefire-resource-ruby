# frozen_string_literal: true

module HireFire
  module Macro
    module Deprecated
      # Provides backward compatibility with the deprecated GoodJob macro.
      # For new implementations, refer to {HireFire::Macro::GoodJob}.
      module GoodJob
        # Retrieves the total number of jobs in the specified queue(s) using GoodJob.
        #
        # This method queries the PostgreSQL database through GoodJob. It's capable
        # of counting jobs across different queues or all queues if none specified.
        # The method checks for the existence of ::GoodJob::Execution or ::GoodJob::Job
        # to determine the base class to use for querying.
        #
        # @param queues [Array<String>] The names of the queues to count.
        #   Pass an empty array or no arguments to count jobs in all queues.
        # @return [Integer] Total number of jobs in the specified queues.
        # @example Counting jobs in all queues
        #   HireFire::Macro::GoodJob.queue
        # @example Counting jobs in the "default" queue
        #   HireFire::Macro::GoodJob.queue("default")
        def queue(*queues)
          base_class = defined?(::GoodJob::Execution) ? ::GoodJob::Execution : ::GoodJob::Job
          scope = base_class.only_scheduled.unfinished
          scope = scope.where(queue_name: queues) if queues.any?
          scope.count
        end
      end
    end
  end
end
