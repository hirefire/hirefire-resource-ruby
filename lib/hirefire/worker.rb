# frozen_string_literal: true

module HireFire
  # Job-metric collector for a declared worker process.
  #
  # @!attribute [r] name
  #   The process name this collector reports under.
  #   @return [String]
  class Worker
    attr_reader :name

    def initialize(name, &sampler)
      @name = name.to_s
      @sampler = sampler
    end

    # Returns the current job metric value from the configured sampler.
    #
    # @return [Numeric]
    def sample
      @sampler.call
    end
  end
end
