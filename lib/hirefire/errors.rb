# frozen_string_literal: true

module HireFire
  module Errors
    class MissingQueueError < StandardError; end

    class JobQueueLatencyUnsupportedError < StandardError; end

    class SampleIncomplete < StandardError; end
  end
end
