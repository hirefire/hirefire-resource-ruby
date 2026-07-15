# frozen_string_literal: true

module HireFire
  # Error types raised by the library and its queue macros.
  module Errors
    # Raised when a queue macro is called without any queue names and the backend requires them
    # (e.g. Bunny).
    class MissingQueueError < StandardError; end

    # Raised when a queue library has no latency metric (e.g. Resque, Bunny).
    class JobQueueLatencyUnsupportedError < StandardError; end
  end
end
