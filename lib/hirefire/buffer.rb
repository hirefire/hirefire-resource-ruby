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
        prune(@web, timestamp)
        @web[timestamp] ||= []
        @web[timestamp] << sample
      end
    end

    # Latest-wins per name: worker samples are point-in-time gauges, so when
    # dispatch is starved (network outage) only the most recent value is worth
    # delivering — the server stamps gauges at arrival, and a stale value under
    # a fresh timestamp would be wrong. This also bounds the buffer at one
    # entry per declared worker.
    def sample_worker(name, sample)
      @mutex.synchronize do
        @workers.delete_if { |entry| entry["name"] == name }
        @workers << {"name" => name, "sample" => sample}
      end
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

    private

    # Insert-side TTL: when dispatch is starved (network outage, a stopped
    # dispatcher) the timestamped buffers must not grow without bound. Seconds
    # older than the TTL would be rejected by the server's staleness window
    # anyway, so dropping them loses nothing. The size guard keeps the common
    # case (dispatch draining every second, a handful of live keys) a single
    # integer comparison.
    def prune(buckets, now)
      return if buckets.size <= @ttl + 5

      cutoff = now - @ttl
      buckets.delete_if { |timestamp, _| timestamp < cutoff }
    end
  end
end
