# frozen_string_literal: true

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
        #   # all queues using ActiveRecord <= 2.3.x mapper.
        #   HireFire::Macro::Delayed::Job.queue(:mapper => :active_record_2)
        #
        #   # only "email" queue with Mongoid mapper.
        #   HireFire::Macro::Delayed::Job.queue("email", :mapper => :mongoid)
        #
        #   # "audio" and "video" queues with ActiveRecord mapper.
        #   HireFire::Macro::Delayed::Job.queue("audio", "video", :mapper => :active_record)
        #
        #   # all queues with a maximum priority of 20
        #   HireFire::Macro::Delayed::Job.queue(:max_priority => 20, :mapper => :active_record)
        #
        #   # all queues with a minimum priority of 5
        #   HireFire::Macro::Delayed::Job.queue(:min_priority => 5, :mapper => :active_record)
        #
        # @param [Array] queues provide one or more queue names, or none for "all".
        #   Last argument can pass in a Hash containing :mapper => :active_record or :mapper => :mongoid
        # @return [Integer] the number of jobs in the queue(s).
        #
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
            c = c.where("priority >= ?", options[:min_priority]) if options.key?(:min_priority)
            c = c.where("priority <= ?", options[:max_priority]) if options.key?(:max_priority)
            c = c.where(:queue => queues) unless queues.empty?
            c.count.tap { ActiveRecord::Base.clear_active_connections! }
          when :active_record_2
            c = ::Delayed::Job
            c = c.scoped(:conditions => ["run_at <= ? AND failed_at is NULL", Time.now.utc])
            c = c.scoped(:conditions => ["priority >= ?", options[:min_priority]]) if options.key?(:min_priority)
            c = c.scoped(:conditions => ["priority <= ?", options[:max_priority]]) if options.key?(:max_priority)
            # There is no queue column in delayed_job <= 2.x
            c.count.tap do
              if ActiveRecord::Base.respond_to?(:clear_active_connections!)
                ActiveRecord::Base.clear_active_connections!
              end
            end
          when :mongoid
            c = ::Delayed::Job
            c = c.where(:failed_at => nil)
            c = c.where(:run_at.lte => Time.now.utc)
            c = c.where(:priority.gte => options[:min_priority]) if options.key?(:min_priority)
            c = c.where(:priority.lte => options[:max_priority]) if options.key?(:max_priority)
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
