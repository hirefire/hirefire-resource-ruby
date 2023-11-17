# frozen_string_literal: true

module HireFire
  module Errors
    module LatencyMethodRenamed
      def latency(*, **)
        raise LatencyMethodRenamedError,
          "The `#{name}.latency` method has been renamed to " \
          "`#{name}.job_queue_latency` since hirefire-resource 1.0.0."
      end
    end
  end
end
