# frozen_string_literal: true

module HireFire
  module Macro
    module Deprecated
      # Provides backward compatibility with the deprecated QC macro.
      # For new implementations, refer to {HireFire::Macro::QC}.
      module QC
        # Retrieves the total number of jobs in the specified queue using Queue Classic.
        #
        # Waiting set only: due unlocked jobs (`scheduled_at` ≤ now, `locked_at` null).
        # Prefer {HireFire::Macro::QC#job_queue_size} for new code.
        #
        # @param queue [String, Symbol] The name of the queue to count.
        #   Defaults to "default" if no queue name is provided.
        # @return [Integer] Total number of waiting jobs in the specified queue.
        # @example Counting jobs in the "default" queue
        #   HireFire::Macro::QC.queue
        # @example Counting jobs in the "critical" queue
        #   HireFire::Macro::QC.queue("critical")
        def queue(queue = "default")
          job_queue_size(queue)
        end
      end
    end
  end
end
