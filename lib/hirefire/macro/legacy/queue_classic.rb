# frozen_string_literal: true

module HireFire
  module Macro
    module Legacy
      # Provides backward compatibility with the legacy QC Macro.
      # For new implementations, refer to {HireFire::Macro::QC}.
      module QC
        # Retrieves the total number of jobs in the specified queue using QueueClassic.
        #
        # This method queries the PostgreSQL database through QueueClassic. It's capable
        # of counting jobs in a specific queue, defaulting to the 'default' queue if none is specified.
        #
        # @param queue [String, Symbol] The name of the queue to count.
        #   Defaults to 'default' if no queue name is provided.
        # @return [Integer] Total number of jobs in the specified queue.
        # @example Counting jobs in the 'default' queue
        #   HireFire::Macro::QC.queue
        # @example Counting jobs in the 'email' queue
        #   HireFire::Macro::QC.queue("email")
        def queue(queue = "default")
          ::QC::Queue.new(queue).count
        end
      end
    end
  end
end
