# frozen_string_literal: true

module HireFire
  module Macro
    module Deprecated
      module Delayed
        module Job
          def queue(*queues)
            queues.flatten!
            options = queues.last.is_a?(Hash) ? queues.pop : {}

            case options[:mapper]
            when :active_record
              query = ::Delayed::Job.where(failed_at: nil, locked_at: nil).where("run_at <= ?", Time.now.utc)
              query = query.where("priority >= ?", options[:min_priority]) if options.key?(:min_priority)
              query = query.where("priority <= ?", options[:max_priority]) if options.key?(:max_priority)
              query = query.where(queue: queues) unless queues.empty?
              query.count
            when :mongoid
              query = ::Delayed::Job.where(:failed_at => nil, :locked_at => nil, :run_at.lte => Time.now.utc)
              query = query.where(:priority.gte => options[:min_priority]) if options.key?(:min_priority)
              query = query.where(:priority.lte => options[:max_priority]) if options.key?(:max_priority)
              query = query.where(:queue.in => queues) unless queues.empty?
              query.count
            else
              raise ArgumentError, "Must pass either :mapper => :active_record or :mapper => :mongoid. " \
                                   "For example: HireFire::Macro::Delayed::Job.queue(\"worker\", mapper: :active_record)"
            end
          end
        end
      end
    end
  end
end
