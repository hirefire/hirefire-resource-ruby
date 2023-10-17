# frozen_string_literal: true

module HireFire
  module Errors
    module QueueMethodRenamed
      # When called, this method raises a QueueMethodRenamedError,
      # indicating that the `.queue` method has been renamed to
      # `.job_queue_size` and should no longer be used.
      #
      # @overload queue(*args, **kwargs)
      #   The method signature allows for any number of positional and
      #   keyword arguments to be passed, though they are not used, as
      #   the method's sole purpose is to raise an error.
      # @raise [QueueMethodRenamedError] when the deprecated `.queue` method is called.
      # @return [void]
      def queue(*, **)
        raise QueueMethodRenamedError,
          "The `#{name}.queue` method has been renamed to " \
          "`#{name}.job_queue_size` since hirefire-resource 1.0.0."
      end
    end
  end
end
