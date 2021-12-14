# frozen_string_literal: true

module HireFire
  module Macro
    module Qu
      extend self

      # Counts the amount of jobs in the (provided) Qu queue(s).
      #
      # @example Qu Macro Usage
      #   HireFire::Macro::Qu.queue # all queues
      #   HireFire::Macro::Qu.queue("email") # only email queue
      #   HireFire::Macro::Qu.queue("audio", "video") # audio and video queues
      #
      # @param [Array] queues provide one or more queue names, or none for "all".
      # @return [Integer] the number of jobs in the queue(s).
      #
      def queue(*queues)
        queues = ::Qu.backend.queues if queues.empty?
        queues.flatten.inject(0) { |memo, queue|
          memo += ::Qu.backend.length(queue)
          memo
        }
      end
    end
  end
end
