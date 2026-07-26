# frozen_string_literal: true

require "set"

module HireFire
  module Utility
    private

    def normalize_queues(queues, allow_empty:)
      queues = queues.flatten.map { |queue| queue.to_s.strip }.reject(&:empty?)

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

