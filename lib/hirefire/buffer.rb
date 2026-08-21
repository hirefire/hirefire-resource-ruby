# frozen_string_literal: true

module HireFire
  class Buffer
    SAMPLE_COUNT_LIMIT = 1_000_000

    def initialize(ttl: 60)
      @metrics = {}
      @mutex = Mutex.new
      @ttl = ttl
    end

    def sample(name, strategy, value)
      return unless value.is_a?(Numeric) && value.finite?

      timestamp = Time.now.to_i
      strategy = strategy.to_s
      @mutex.synchronize do
        series = series_for(name, strategy)
        prune(series, timestamp)
        if strategy == "rqt"
          bucket = series[timestamp] ||= {sum: 0.0, count: 0}
          return if bucket[:count] >= SAMPLE_COUNT_LIMIT

          bucket[:sum] += value
          bucket[:count] += 1
        else
          series[timestamp] = value
        end
      end
    end

    def flush
      @mutex.synchronize do
        metrics = @metrics
        @metrics = {}
        metrics
      end
    end

    def discard_inherited
      @mutex.synchronize { @metrics = {} }
    end

    def reinit_after_fork
      @mutex = Mutex.new
      @metrics = {}
    end

    def repopulate(name, strategy, data)
      strategy = strategy.to_s
      return unless strategy == "rqt"

      now = Time.now.to_i
      @mutex.synchronize do
        series = series_for(name, strategy)
        data.each do |timestamp, bucket|
          next if timestamp < now - @ttl

          sum, count = bucket_parts(bucket)
          next if count <= 0

          existing = series[timestamp]
          series[timestamp] = if existing.is_a?(Hash)
            clamp_rqt_bucket(
              existing[:sum] + sum,
              existing[:count] + count
            )
          else
            clamp_rqt_bucket(sum, count)
          end
        end
        prune(series, now)
      end
    end

    private

    def clamp_rqt_bucket(sum, count)
      if count > SAMPLE_COUNT_LIMIT
        mean = sum / count
        {sum: mean * SAMPLE_COUNT_LIMIT, count: SAMPLE_COUNT_LIMIT}
      else
        {sum: sum, count: count}
      end
    end

    def bucket_parts(bucket)
      case bucket
      when Hash
        sum = bucket[:sum] || bucket["sum"]
        count = bucket[:count] || bucket["count"]
        [sum.to_f, count.to_i]
      else
        [0.0, 0]
      end
    end

    def series_for(name, strategy)
      @metrics[name] ||= {}
      @metrics[name][strategy] ||= {}
    end

    def prune(buckets, now)
      return if buckets.size <= @ttl + 5

      cutoff = now - @ttl
      buckets.delete_if { |timestamp, _| timestamp < cutoff }
    end
  end
end
