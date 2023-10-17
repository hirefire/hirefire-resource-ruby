# frozen_string_literal: true

module HireFire
  module Errors
    module JobQueueLatencyUnsupported
      def job_queue_latency(*, **)
        raise HireFire::Errors::JobQueueLatencyUnsupportedError,
          "#{name} currently does not support job queue latency measurements."
      end
    end
  end
end
