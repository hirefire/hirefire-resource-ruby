# frozen_string_literal: true

module HireFire
  module Errors
    # Raised when no queue is specified.  This indicates a
    # configuration error where a queue name is expected but was not
    # provided.
    class MissingQueueError < StandardError; end

    # Raised when attempting to measure job queue latency for a queue
    # that does not support such measurement.  This error signifies
    # that the underlying system cannot provide latency information.
    class JobQueueLatencyUnsupportedError < StandardError; end

    # Raised when the `queue` method is called on an object that has
    # since renamed this method to `job_queue_size`.
    class QueueMethodRenamedError < StandardError; end

    # Raised when the `latency` method is called on an object that has
    # since renamed this method to `job_queue_latency`.
    class LatencyMethodRenamedError < StandardError; end
  end
end
