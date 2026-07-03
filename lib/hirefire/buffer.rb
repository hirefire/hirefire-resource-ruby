# frozen_string_literal: true

module HireFire
  class Buffer
    def initialize(ttl: 60)
      @web = {}
      @workers = {}
      @cpu = {}
      @mutex = Mutex.new
      @ttl = ttl
    end

    def sample_web(sample)
      timestamp = Time.now.to_i
      @mutex.synchronize do
        prune(@web, timestamp)
        @web[timestamp] ||= []
        @web[timestamp] << sample
      end
    end

    def sample_worker(name, sample)
      @mutex.synchronize { @workers[name] = sample }
    end

    def sample_cpu(name, value)
      timestamp = Time.now.to_i
      @mutex.synchronize do
        @cpu[name] ||= {}
        prune(@cpu[name], timestamp)
        @cpu[name][timestamp] ||= []
        @cpu[name][timestamp] << value
      end
    end

    def flush
      @mutex.synchronize do
        web, workers, cpu = @web, @workers, @cpu
        @web, @workers, @cpu = {}, {}, {}

        {
          web: web,
          workers: workers.map { |name, sample| {"name" => name, "sample" => sample} },
          cpu: cpu
        }
      end
    end

    def discard_inherited
      @mutex.synchronize do
        @workers = {}
        @cpu = {}
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

    private

    def prune(buckets, now)
      return if buckets.size <= @ttl + 5

      cutoff = now - @ttl
      buckets.delete_if { |timestamp, _| timestamp < cutoff }
    end
  end
end
