# frozen_string_literal: true

module HireFire
  module Errors
    # Mixin that defines {#job_queue_latency} as always raising
    # {JobQueueLatencyUnsupportedError}. Extended by queue macros that have no latency metric
    # (Resque, Bunny). Also reports plan strategy support so the lease plan path can skip
    # +"jql"+ without calling the method every sample tick.
    module JobQueueLatencyUnsupported
      # Job queue latency is not supported for this backend. Calling this always raises.
      #
      # @raise [HireFire::Errors::JobQueueLatencyUnsupportedError] always.
      def job_queue_latency(*, **)
        raise HireFire::Errors::JobQueueLatencyUnsupportedError,
          "#{name} currently does not support job queue latency measurements."
      end

      # Latency-only backends support size plans, not +jql+.
      # Extend this module *after* {HireFire::Plan::Hooks} so this override wins.
      #
      # @param strategy [String, Symbol]
      # @return [Boolean]
      def supports_plan_strategy?(strategy)
        strategy.to_s == "jqs"
      end
    end
  end
end
