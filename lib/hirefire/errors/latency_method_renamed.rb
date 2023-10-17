# frozen_string_literal: true

module HireFire
  module Errors
    module LatencyMethodRenamed
      # This method raises a LatencyMethodRenamedError to indicate
      # that the `.latency` method has been renamed to
      # `.job_queue_latency` and should no longer be used.
      #
      # @overload latency(*args, **kwargs)
      #   Allows any number of positional and keyword arguments to be
      #   passed, which are not utilized.  The method's primary
      #   function is to raise a deprecation error.
      # @raise [LatencyMethodRenamedError] when the deprecated `.latency` method is called.
      # @return [void]
      def latency(*, **)
        raise LatencyMethodRenamedError,
          "The `#{name}.latency` method has been renamed to " \
          "`#{name}.job_queue_latency` since hirefire-resource 1.0.0."
      end
    end
  end
end
