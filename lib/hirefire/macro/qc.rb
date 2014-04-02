# encoding: utf-8

module HireFire
  module Macro
    module QC
      extend self

      # Queries the PostgreSQL database through QueueClassic in order to
      # count the amount of jobs in the specified queue.
      #
      # @example QueueClassic Macro Usage
      #   HireFire::Macro::QC.queue # counts the `default` queue.
      #   HireFire::Macro::QC.queue("email") # counts the `email` queue.
      #
      # @param [String, Symbol, nil] queue the queue name to count. (default: `default`)
      # @return [Integer] the number of jobs in the queue(s).
      #
      def queue(queue = "default")
        ::QC::Queue.new(queue).count
      end
    end
  end
end

