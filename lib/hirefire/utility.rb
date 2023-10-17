# frozen_string_literal: true

module HireFire
  module Utility
    extend self

    # Construct the set of queues to be used in querying.
    #
    # If no queues are provided or if they are nested, it will flatten
    # and process them.  The method raises a
    # HireFire::Errors::MissingQueueError if no queues are specified.
    #
    # @param queues [Array<String, Symbol>] list of queues (can accept nested arrays).
    # @return [Set<String>] the processed set of queue names.
    # @raise [HireFire::Errors::MissingQueueError] if no queues are specified.
    def construct_queues(queues)
      queues = queues.flatten.map(&:to_s)

      if queues.any?
        Set.new(queues)
      else
        raise HireFire::Errors::MissingQueueError, "No queue was specified. Please specify at least one queue."
      end
    end
  end
end
