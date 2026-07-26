# frozen_string_literal: true

module HireFire
  module Source
    # Collection of local {HireFire::Source::JobQueue} sources declared on the configuration.
    class JobQueues
      include Enumerable

      def initialize
        @job_queues = []
      end

      # @param job_queue [HireFire::Source::JobQueue]
      # @return [Array<HireFire::Source::JobQueue>]
      def <<(job_queue)
        @job_queues << job_queue
      end

      # Case-insensitive match (same rule as config duplicate-name detection). The
      # returned source keeps its canonical declared name for emit.
      #
      # @param name [String]
      # @return [HireFire::Source::JobQueue, nil]
      def find_by_name(name)
        needle = name.to_s
        @job_queues.find { |job_queue| job_queue.name.casecmp?(needle) }
      end

      # @yieldparam job_queue [HireFire::Source::JobQueue]
      # @return [Enumerator] if no block is given
      def each(&block)
        @job_queues.each(&block)
      end

      # Samples a job-queue source and buffers a valid metric under the given wire strategy.
      #
      # @param job_queue [HireFire::Source::JobQueue]
      # @param strategy [String] +jql+ or +jqs+
      # @return [void]
      def sample_job_queue(job_queue, strategy)
        value = job_queue.sample

        unless valid_sample?(value)
          Log.safe(logger, :error, "[HireFire] The sampler for #{job_queue.name.inspect} returned " \
            "#{value.inspect}, expected a non-negative number. Sample dropped.")
          return
        end

        HireFire.configuration.buffer.sample(job_queue.name, strategy.to_s, coerce_sample(value))
      rescue => e
        Log.safe(logger, :error, "[HireFire] The sampler for #{job_queue.name.inspect} raised " \
          "#{e.class}: #{e.message}")
      end

      private

      def valid_sample?(value)
        value.is_a?(Numeric) && value.finite? && value >= 0
      end

      def coerce_sample(value)
        (value.is_a?(Integer) || value.is_a?(Float)) ? value : value.to_f
      end

      def logger
        HireFire.configuration.logger
      end
    end
  end
end
