# frozen_string_literal: true

module HireFire
  module Errors
    module JobQueueLatencyUnsupported
      # This method raises a JobQueueLatencyUnsupportedError to
      # indicate that the `.job_queue_latency` method is not supported
      # by the class.  This is intended to be included in classes that
      # do not support latency measurements.
      #
      # @overload job_queue_latency(*args, **kwargs)
      #   This method accepts any number of positional and keyword
      #   arguments, but does not use them, as its only function is to
      #   raise an exception indicating the lack of support for
      #   latency measurements.
      # @raise [HireFire::Errors::JobQueueLatencyUnsupportedError]
      #   indicating that the class does not support job queue latency measurements.
      # @return [void]
      def job_queue_latency(*, **)
        raise HireFire::Errors::JobQueueLatencyUnsupportedError, "#{name} does not support job queue latency measurements."
      end
    end
  end
end
