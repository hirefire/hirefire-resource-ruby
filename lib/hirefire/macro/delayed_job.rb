# encoding: utf-8

module HireFire
  module Macro
    module Delayed
      module Job
        extend self

        # Returns the job quantity for the provided queue(s).
        #
        # @example Delayed::Job Macro Usage
        #
        #   # all queues using ActiveRecord mapper.
        #   HireFire::Macro::Delayed::Job.queue(:mapper => :active_record)
        #
        #   # only "email" queue with Mongoid mapper.
        #   HireFire::Macro::Delayed::Job.queue("email", :mapper => :mongoid)
        #
        #   # "audio" and "video" queues with ActiveRecord mapper.
        #   HireFire::Macro::Delayed::Job.queue("audio", "video", :mapper => :active_record)
        #
        # @param [Array] queues provide one or more queue names, or none for "all".
        #   Last argument can pass in a Hash containing :mapper => :active_record or :mapper => :mongoid
        #
        # @return [Integer] the number of jobs in the queue(s).
        def queue(*queues)
          queues.flatten!

          if queues.last.is_a?(Hash)
            options = queues.pop
          else
            options = {}
          end

          case options[:mapper]
          when :active_record
            c = ::Delayed::Job
            c = c.where(:failed_at => nil)
            c = c.where("run_at <= ?", Time.now.utc)
            c = c.where(:queue => queues) unless queues.empty?
            c.count
          when :mongoid
            c = ::Delayed::Job
            c = c.where(:failed_at => nil)
            c = c.where(:run_at.lte => Time.now.utc)
            c = c.where(:queue.in => queues) unless queues.empty?
            c.count
          else
            raise %{Must pass in :mapper => :active_record or :mapper => :mongoid\n} +
              %{For example: HireFire::Macro::Delayed::Job.queue("worker", :mapper => :active_record)}
          end
        end
      end
    end
  end
end

