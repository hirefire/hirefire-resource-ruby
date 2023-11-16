# frozen_string_literal: true

module HireFire
  # The Worker class is responsible for measuring job queue metrics for various worker libraries.
  # It does not report these metrics directly to HireFire's servers. Instead, it exposes a `call`
  # method that measures the current metric value (latency or size). These metrics are then made
  # available via a JSON endpoint through the provided middleware, which is periodically accessed by
  # HireFire's servers to gather recent metric values.
  #
  # The class is initialized with a name, matching the worker dyno designation in the Procfile, and
  # a block of code that defines the metric measuring logic. The provided block must return an
  # integer representing either the job queue latency or size metric and can contain provided macros
  # or custom logic for specific queue metrics.
  class Worker
    # Provides read access to the worker's name.
    attr_reader :name

    # Initializes a new Worker instance with a given name and a block of work.
    #
    # @param name [String] The name of the worker, corresponding to the Procfile's dyno name.
    # @param block [Proc] A block of code that returns an integer representing the queue metric.
    def initialize(name, &block)
      @name = name
      @block = block
    end

    # Executes the block of work passed during initialization and returns its result, which is an
    # integer representing the measured queue metric (latency or size).  The result is made
    # available for retrieval via the middleware.
    #
    # @return [Integer] The queue metric result from the executed block.
    def call
      @block.call
    end
  end
end
