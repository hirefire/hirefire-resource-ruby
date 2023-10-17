# frozen_string_literal: true

module HireFire
  module Utility
    extend self

    private

    def normalize_queues(queues, allow_empty:)
      queues = queues.flatten.map { |queue| queue.to_s.strip }

      if queues.any?
        Set.new(queues)
      elsif allow_empty
        Set.new
      else
        raise HireFire::Errors::MissingQueueError,
          "No queue was specified. Please specify at least one queue."
      end
    end
  end
end
