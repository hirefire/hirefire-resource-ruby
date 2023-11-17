# frozen_string_literal: true

module HireFire
  module Utility
    extend self

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
