# frozen_string_literal: true

module HireFire
  module Macro
    module Deprecated
      # Provides backward compatibility with the deprecated QC macro.
      # For new implementations, refer to {HireFire::Macro::QC}.
      module QC
        # Retrieves the total number of jobs in the specified queue using QueueClassic.
        #
        # This method queries the PostgreSQL database through QueueClassic. It's capable of counting
        # jobs in a specific queue, defaulting to the "default" queue if none is specified.
        # It utilizes the QC::Queue class to interface with the QueueClassic system.
        #
        # @param queue [String, Symbol] The name of the queue to count.
        #   Defaults to "default" if no queue name is provided.
        # @return [Integer] Total number of jobs in the specified queue.
        # @example Counting jobs in the "default" queue
        #   HireFire::Macro::QC.queue
        # @example Counting jobs in the "critical" queue
        #   HireFire::Macro::QC.queue("critical")
        def queue(queue = "default")
          ::QC::Queue.new(queue.to_s).count
        end
      end
    end
  end
end
