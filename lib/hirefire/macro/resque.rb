# encoding: utf-8

module HireFire
  module Macro
    module Resque
      extend self

      # Counts the amount of jobs in the (provided) Resque queue(s).
      #
      # @example Resque Macro Usage
      #   HireFire::Macro::Resque.queue # all queues
      #   HireFire::Macro::Resque.queue("email") # only email queue
      #   HireFire::Macro::Resque.queue("audio", "video") # audio and video queues
      #
      # @param [Array] queues provide one or more queue names, or none for "all".
      #
      # @return [Integer] the number of jobs in the queue(s).
      def queue(*queues)
        if queues.empty?
          working = ::Resque.working.select(&:working?).count
          return ::Resque.info[:pending].to_i + working
        end
        queues = queues.flatten.map(&:to_s)
        pending = queues.inject(0) { |memo, queue| memo += ::Resque.size(queue); memo }

        # Number of working workers that process jobs for any of the specified queues
        working = ::Resque.working.select(&:working?).map(&:queues).select{|worker_queues| (worker_queues & queues).any?}.count
        
        pending + working
      end
    end
  end
end
