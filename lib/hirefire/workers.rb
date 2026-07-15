# frozen_string_literal: true

module HireFire
  # Collection of job-metric Worker collectors declared on the configuration.
  class Workers
    include Enumerable

    def initialize
      @workers = []
    end

    # Adds a worker collector to the collection.
    #
    # @param worker [HireFire::Worker]
    # @return [Array<HireFire::Worker>]
    def <<(worker)
      @workers << worker
    end

    # Iterates over each worker collector.
    #
    # @yieldparam worker [HireFire::Worker]
    # @return [Enumerator] if no block is given
    def each(&block)
      @workers.each(&block)
    end

    # Samples every worker and buffers valid metric values.
    #
    # A value is valid when it is a non-boolean, non-negative, finite number. Invalid or raised
    # sampler results are logged and skipped, not re-raised.
    #
    # @return [void]
    def sample
      each do |worker|
        value = worker.sample

        unless valid_sample?(value)
          Log.safe(logger, :error, "[HireFire] The sampler for dyno #{worker.name.inspect} returned " \
            "#{value.inspect}, expected a non-negative number. Sample dropped.")
          next
        end

        HireFire.configuration.buffer.sample_worker(worker.name, coerce_sample(value))
      rescue => e
        Log.safe(logger, :error, "[HireFire] The sampler for dyno #{worker.name.inspect} raised " \
          "#{e.class}: #{e.message}")
      end
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
