# frozen_string_literal: true

module HireFire
  module Plan
    # Uniform plan hooks for every queue macro. Plan always calls these; adapters
    # override when they accept lease options or need connection kwargs.
    #
    # For lease JSON +options+, prefer a strategy → field → type schema and
    # +extract_plan_options+ so filtering/coercion stays in one place.
    module Hooks
      # Filter/coerce plan JSON +options+ for +strategy+ (+"jql"+ / +"jqs"+).
      #
      # @param strategy [String]
      # @param options [Object] raw lease +options+ (usually a Hash)
      # @return [Hash] keyword args safe to pass to +job_queue_latency+ / +job_queue_size+
      def plan_options(strategy, options)
        {}
      end

      # Connection-related kwargs from the environment (e.g. Bunny AMQP URL).
      #
      # @return [Hash]
      def plan_connection_options
        {}
      end

      # Whether this adapter can sample +strategy+ (+"jql"+ / +"jqs"+). Defaults
      # to true for known strategies. Macros that cannot measure latency override
      # via {HireFire::Errors::JobQueueLatencyUnsupported}.
      #
      # @param strategy [String, Symbol]
      # @return [Boolean]
      def supports_plan_strategy?(strategy)
        HireFire::Plan.known_strategy?(strategy)
      end

      # Open process-local state for one {HireFire::Dispatcher#sample_job_queues} wave.
      # Default is a no-op. Adapters with sample-scoped caches (e.g. Sidekiq DueCache)
      # override and may return an opaque token for {#after_sample_job_queues}.
      #
      # Called for every allowlisted macro on each job-queue sample wave, whether or
      # not that adapter appears in the current lease plan (legacy dyno blocks may
      # still invoke the macro).
      #
      # @return [Object, nil] opaque token passed to +after_sample_job_queues+
      def before_sample_job_queues
        nil
      end

      # Close process-local sample-wave state opened by {#before_sample_job_queues}.
      # Default is a no-op. Called from +ensure+ even when a sampler raises.
      #
      # @param token [Object, nil] value returned by +before_sample_job_queues+
      # @return [void]
      def after_sample_job_queues(token = nil)
      end

      # Reset process-local macro state after fork (or abandoned inherited state).
      # Default is a no-op. Called next to buffer reinit on the same dispatcher sites.
      #
      # @return [void]
      def reinit_after_fork
      end

      # Slice and coerce lease +options+ using a strategy-keyed schema.
      #
      # +schema+ maps strategy string → field name string → type symbol
      # (+:boolean+, +:non_negative_integer+). Unknown strategies, non-Hash
      # options, unknown fields, and failed coercions are dropped.
      #
      # @param strategy [String, Symbol]
      # @param options [Object]
      # @param schema [Hash{String => Hash{String => Symbol}}]
      # @return [Hash{Symbol => Object}]
      def extract_plan_options(strategy, options, schema)
        return {} unless options.is_a?(Hash)

        fields = schema[strategy.to_s]
        return {} unless fields

        options.each_with_object({}) do |(key, value), out|
          key = key.to_s
          type = fields[key]
          next unless type

          coerced = coerce_plan_value(type, value)
          out[key.to_sym] = coerced unless coerced.nil?
        end
      end

      # Coerce a single plan option value. Returns +nil+ when the value is
      # not acceptable for +type+ (caller drops the key).
      #
      # @param type [Symbol] +:boolean+ or +:non_negative_integer+
      # @param value [Object]
      # @return [Object, nil]
      def coerce_plan_value(type, value)
        case type
        when :boolean
          return true if value == true
          return false if value == false

          nil
        when :non_negative_integer
          case value
          when Integer
            value if value >= 0
          when String
            return nil unless value.match?(/\A[+-]?\d+\z/)

            int = Integer(value, 10)
            int if int >= 0
          end
        end
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
