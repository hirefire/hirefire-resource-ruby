# frozen_string_literal: true

module HireFire
  module Plan
    module Hooks
      def plan_options(strategy, options)
        {}
      end

      def plan_connection_options
        {}
      end

      def supports_plan_strategy?(strategy)
        HireFire::Plan.known_strategy?(strategy)
      end

      def queues_required?
        false
      end

      def before_sample_job_queues
        nil
      end

      def after_sample_job_queues(token = nil)
      end

      def reinit_after_fork
      end

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
