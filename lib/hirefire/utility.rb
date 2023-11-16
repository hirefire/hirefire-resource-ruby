# frozen_string_literal: true

module HireFire
  module Utility
    extend self

    # Constructs a set of queue names for querying. It processes the provided queues array,
    # flattening any nested arrays (e.g., [['queue1', 'queue2'], 'queue3'] becomes ['queue1',
    # 'queue2', 'queue3']) and converts them to strings. This method raises a
    # HireFire::Errors::MissingQueueError if no queues are specified.
    #
    # @param queues [Array<String, Symbol>] A list of queues, which can include nested arrays.
    # @return [Set<String>] The processed set of queue names.
    # @raise [HireFire::Errors::MissingQueueError] If no queues are specified.
    def construct_queues(queues)
      queues = queues.flatten.map(&:to_s)

      if queues.any?
        Set.new(queues)
      else
        raise HireFire::Errors::MissingQueueError,
          "No queue was specified. Please specify at least one queue."
      end
    end
  end
end
