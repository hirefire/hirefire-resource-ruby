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
        HireFire.configuration.buffer.sample_worker(worker.name, worker.sample)
      end
    end
  end
end
