# frozen_string_literal: true

module HireFire
  module Errors
    class MissingQueueError < StandardError; end

    class JobQueueLatencyUnsupportedError < StandardError; end

    class QueueMethodRenamedError < StandardError; end

    class LatencyMethodRenamedError < StandardError; end
  end
end
