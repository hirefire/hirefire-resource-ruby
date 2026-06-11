# frozen_string_literal: true

module HireFire
  class Buffer
    def initialize(ttl: 60)
      @web = {}
      @workers = []
      @cpu = {}
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

    def sample_cpu(name, value)
      timestamp = Time.now.to_i
      @mutex.synchronize do
        @cpu[name] ||= {}
        @cpu[name][timestamp] ||= []
        @cpu[name][timestamp] << value
      end
    end

    def flush
      @mutex.synchronize do
        web, workers, cpu = @web, @workers, @cpu
        @web, @workers, @cpu = {}, [], {}
        {web: web, workers: workers, cpu: cpu}
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
