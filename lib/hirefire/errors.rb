# frozen_string_literal: true

module HireFire
  module Errors
    # Raised when no queue name is specified for macros that explicitly require it.  This error
    # occurs during when calling macro functions where at least one queue name must be provided to
    # measure job queue metrics.
    class MissingQueueError < StandardError; end

    # Raised when attempting to measure job queue latency for a queue system that doesn't reliably
    # support such measurements. This error highlights the potential unreliability or lack of
    # support for latency measurement in the underlying queue system.
    class JobQueueLatencyUnsupportedError < StandardError; end

    # Raised when the `queue` method from an earlier version of the library is called but has been
    # renamed to `job_queue_size` in a newer version. This error assists users migrating from older
    # versions to adapt to the updated API.
    class QueueMethodRenamedError < StandardError; end

    # Raised when the `latency` method from an earlier version of the library is called but has been
    # renamed to `job_queue_latency` in a newer version. This error assists users migrating from
    # older versions to adapt to the updated API.
    class LatencyMethodRenamedError < StandardError; end
  end
end
