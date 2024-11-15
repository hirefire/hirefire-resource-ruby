# frozen_string_literal: true

module HireFire
  module Macro
    module Deprecated
      module Delayed
        # Provides backward compatibility with the deprecated Delayed::Job macro.
        # For new implementations, refer to {HireFire::Macro::Delayed::Job}.
        module Job
          # Retrieves the total number of jobs in the specified queue(s).
          #
          # This method supports querying jobs across different ORMs (Object-Relational Mappings)
          # such as ActiveRecord and Mongoid. It allows specifying queue names and priority limits.
          #
          # @param queues [Array<String, Symbol>] Queue names to query.
          #   The last argument can be a Hash with :mapper, :min_priority, and/or :max_priority keys.
          # @option queues [Symbol] :mapper (:active_record, :active_record_2, :mongoid) The ORM mapper to use.
          # @option queues [Integer, nil] :min_priority (nil) The minimum job priority to include in the count.
          #   If not specified, no lower limit is applied.
          # @option queues [Integer, nil] :max_priority (nil) The maximum job priority to include in the count.
          #   If not specified, no upper limit is applied.
          # @return [Integer] Total number of jobs in the specified queues.
          # @raise [ArgumentError] Raises an error if a valid :mapper option is not provided.
          # @example Querying all queues using ActiveRecord mapper
          #   HireFire::Macro::Delayed::Job.queue(mapper: :active_record)
          # @example Querying specific queues with Mongoid mapper
          #   HireFire::Macro::Delayed::Job.queue("default", mapper: :mongoid)
          # @example Query all queues scoped to a priority range
          #   HireFire::Macro::Delayed::Job.queue(max_priority: 20, min_priority: 5, mapper: :active_record)
          def queue(*queues)
            queues.flatten!
            options = queues.last.is_a?(Hash) ? queues.pop : {}

            case options[:mapper]
            when :active_record
              query = ::Delayed::Job.where(failed_at: nil, run_at: ..Time.now.utc)
              query = query.where(priority: options[:min_priority]..) if options.key?(:min_priority)
              query = query.where(priority: ..options[:max_priority]) if options.key?(:max_priority)
              query = query.where(queue: queues) unless queues.empty?
              query.count
            when :active_record_2
              # Note: There is no queue column in delayed_job <= 2.x
              query = ::Delayed::Job.scoped(conditions: ["run_at <= ? AND failed_at is NULL", Time.now.utc])
              query = query.scoped(conditions: ["priority >= ?", options[:min_priority]]) if options.key?(:min_priority)
              query = query.scoped(conditions: ["priority <= ?", options[:max_priority]]) if options.key?(:max_priority)
              query.count
            when :mongoid
              query = ::Delayed::Job.where(:failed_at => nil, :run_at.lte => Time.now.utc)
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
