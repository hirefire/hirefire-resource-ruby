# frozen_string_literal: true

module HireFire
  module Errors
    module LatencyMethodRenamed
      def latency(*, **)
        raise LatencyMethodRenamedError, <<~MSG
          The `#{name}.latency` method has been renamed to `#{name}.job_queue_latency`.
          Note that all macro functions now require you to pass in the queue names explicitly.

          For more information, see CHANGELOG.md in:

            $ gem open hirefire-resource

          Contact support for any questions or assistance.
        MSG
      end
    end
  end
end
