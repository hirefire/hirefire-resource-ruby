# frozen_string_literal: true

module HireFire
  class Workers
    include Enumerable

    def initialize
      @workers = []
    end

    def <<(worker)
      @workers << worker
    end

    def each(&block)
      @workers.each(&block)
    end

    def sample
      each do |worker|
        value = worker.sample

        unless valid_sample?(value)
          logger.error "[HireFire] The sampler for dyno #{worker.name.inspect} returned " \
            "#{value.inspect}, expected a non-negative number. Sample dropped."
          next
        end

        HireFire.configuration.buffer.sample_worker(worker.name, coerce_sample(value))
      rescue => e
        logger.error "[HireFire] The sampler for dyno #{worker.name.inspect} raised " \
          "#{e.class}: #{e.message}"
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
