# frozen_string_literal: true

module HireFire
  module Errors
    class MissingQueueError < StandardError; end

    class JobQueueLatencyUnsupportedError < StandardError; end

    class SampleIncompleteError < StandardError; end

    class RequestError < StandardError; end

    class MissingSamplerError < StandardError; end

    class DuplicateDynoError < StandardError; end
  end
end
