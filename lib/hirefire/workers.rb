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

    # Samples every worker, isolating each: one raising sampler (its queue
    # backend being down is the realistic case) must not block the others, and
    # must never propagate into the dispatcher loop. Values are validated here
    # rather than trusted: the sampler block is user code, and a non-numeric or
    # non-finite value would be silently discarded (or worse) downstream.
    def sample
      each do |worker|
        begin
          value = worker.sample
        rescue => e
          logger.error "[HireFire] The sampler for dyno #{worker.name.inspect} raised " \
            "#{e.class}: #{e.message}"
          next
        end

        unless value.is_a?(Numeric) && value.finite? && value >= 0
          logger.error "[HireFire] The sampler for dyno #{worker.name.inspect} returned " \
            "#{value.inspect}; expected a non-negative number. Sample dropped."
          next
        end

        HireFire.configuration.buffer.sample_worker(worker.name, value)
      end
    end

    private

    def logger
      HireFire.configuration.logger
    end
  end
end
