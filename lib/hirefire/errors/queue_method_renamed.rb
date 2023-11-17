# frozen_string_literal: true

module HireFire
  module Errors
    module QueueMethodRenamed
      def queue(*, **)
        raise QueueMethodRenamedError,
          "The `#{name}.queue` method has been renamed to " \
          "`#{name}.job_queue_size` since hirefire-resource 1.0.0."
      end
    end
  end
end
