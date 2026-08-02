# frozen_string_literal: true

module HireFire
  module Macro
    module Deprecated
      # Provides backward compatibility with the deprecated Que macro.
      # For new implementations, refer to {HireFire::Macro::Que}.
      module Que
        # Retrieves the total number of jobs in the specified queue(s) using Que.
        #
        # Waiting set only: due jobs that are not session advisory-locked (same set as
        # {HireFire::Macro::Que#job_queue_size}). Prefer that method for new code.
        #
        # @param queues [Array<String, Symbol>] The names of the queues to count.
        #   Pass an empty array or no arguments to count jobs in all queues.
        # @return [Integer] Total number of waiting jobs in the specified queues.
        # @example Counting jobs in all queues
        #   HireFire::Macro::Que.queue
        # @example Counting jobs in the "default" queue
        #   HireFire::Macro::Que.queue("default")
        def queue(*queues)
          job_queue_size(*queues)
        end
      end
    end
  end
end
