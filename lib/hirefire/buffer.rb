# frozen_string_literal: true

module HireFire
  class Buffer
    def initialize(ttl: 60)
      @web = {}
      @workers = []
      @mutex = Mutex.new
      @ttl = ttl
    end

    def sample_web(sample)
      timestamp = Time.now.to_i
      @mutex.synchronize do
        @web[timestamp] ||= []
        @web[timestamp] << sample
      end
    end

    def sample_worker(name, sample)
      @mutex.synchronize do
        @workers << {"name" => name, "sample" => sample}
      end
    end

    def flush
      @mutex.synchronize do
        web, workers = @web, @workers
        @web, @workers = {}, []
        {web: web, workers: workers}
      end
    end

    def repopulate_web(data)
      now = Time.now.to_i
      @mutex.synchronize do
        data.each do |timestamp, samples|
          next if timestamp < now - @ttl
          @web[timestamp] ||= []
          @web[timestamp].concat(samples)
        end
      end
    end
  end
end
