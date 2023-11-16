# frozen_string_literal: true

module HireFire
  # The Worker class is responsible for measuring job queue metrics for various worker libraries and
  # making these metrics available to HireFire's servers. It is initialized with a name and a block
  # of code that defines the metric measuring logic.
  class Worker
    # Provides read access to the worker's name.
    attr_reader :name

    # Initializes a new instance of the Worker class with a given name and a block of work. The name
    # should correspond to the worker dyno designation in the Procfile, such as 'worker' or
    # 'mailer'.  The provided block must return an integer that represents either the job queue
    # latency or job queue size metric. This block is expected to contain either one of the provided
    # macros for common measurement tasks or custom logic tailored to the specific queue metric
    # being monitored.
    #
    # @param name [String] The name of the worker, corresponding to the Procfile's dyno name.
    # @param block [Proc] A block of code that returns an integer representing the queue metric.
    def initialize(name, &block)
      @name = name
      @block = block
    end

    # Executes the block of work passed during initialization and returns its result. This result
    # should be an integer representing the measured queue metric (latency or size) that will be
    # made available to HireFire's servers.
    #
    # @return [Integer] The queue metric result from the executed block.
    def call
      @block.call
    end
  end
end
