# frozen_string_literal: true

module HireFire
  module Errors
    module JobQueueLatencyUnsupported
      # Job queue latency is not supported for this backend — calling this always raises.
      #
      # @raise [HireFire::Errors::JobQueueLatencyUnsupportedError] always.
      def job_queue_latency(*, **)
        raise HireFire::Errors::JobQueueLatencyUnsupportedError,
          "#{name} currently does not support job queue latency measurements."
      end
    end
  end
end
