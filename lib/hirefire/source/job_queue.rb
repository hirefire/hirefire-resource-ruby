# frozen_string_literal: true

module HireFire
  module Source
    # Job-queue source: one declared local sampler for a process name (feeds +jql+ / +jqs+).
    #
    # Samples a job backend queue (depth or oldest age), not an individual job.
    #
    # @!attribute [r] name
    #   The process name this source reports under.
    #   @return [String]
    class JobQueue
      attr_reader :name

      def initialize(name, &sampler)
        @name = name.to_s
        @sampler = sampler
      end

      # Returns the current job-queue metric value from the configured sampler.
      #
      # @return [Numeric]
      def sample
        @sampler.call
      end
    end
  end
end
