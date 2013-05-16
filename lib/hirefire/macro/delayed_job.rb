# encoding: utf-8

module HireFire
  module Macro
    module Delayed
      module Job
        extend self

        # Determines whether `ActiveRecord (3)` or `Mongoid` is being used.
        # Once determined, it will build the appropriate query criteria in order
        # to count the amount of jobs in a given queue and return the result.
        #
        # @example Delayed::Job Macro Usage
        #   HireFire::Macro::Delayed::Job.queue # all queues
        #   HireFire::Macro::Delayed::Job.queue("email") # only email queue
        #   HireFire::Macro::Delayed::Job.queue("audio", "video") # audio and video queues
        #
        # @param [Array] queues provide one or more queue names, or none for "all".
        #
        # @return [Integer] the number of jobs in the queue(s).
        def queue(*queues)
          queues.flatten!

          if defined?(Mongoid)
            c = ::Delayed::Job
            c = c.where(:failed_at => nil)
            c = c.where(:run_at.lte => Time.now.utc)
            c = c.where(:queue.in => queues) unless queues.empty?
            c.count
          elsif defined?(ActiveRecord)
            c = ::Delayed::Job
            c = c.where(:failed_at => nil)
            c = c.where("run_at <= ?", Time.now.utc)
            c = c.where(:queue => queues) unless queues.empty?
            c.count
          else
            raise "HireFire could not detect ActiveRecord or Mongoid for HireFire::Macro::Delayed::Job."
          end
        end
      end
    end
  end
end

