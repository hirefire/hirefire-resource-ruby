# encoding: utf-8
require 'que/active_record/model'

module HireFire
  module Macro
    module Que
      extend self

      # Queries the PostgreSQL database through Que in order to
      # count the amount of jobs in the specified queue.
      #
      # @example Queue Macro Usage
      #   HireFire::Macro::Que.queue # counts all queues.
      #   HireFire::Macro::Que.queue("email") # counts the `email` queue.
      #
      # @param [String] queue the queue name to count. (default: nil # gets all queues)
      # @return [Integer] the number of jobs in the queue(s).
      #
      def queue(*queues)
        jobs = ::Que::ActiveRecord::Model.not_finished.not_expired.not_scheduled

        if queues.none?
          jobs.count
        else
          jobs.where(queue: queues).count
        end
      end
    end
  end
end
