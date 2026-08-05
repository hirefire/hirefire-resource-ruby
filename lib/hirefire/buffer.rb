# frozen_string_literal: true

module HireFire
  class Buffer
    # Per-leaf request count cap (mirrors server SAMPLE_COUNT_LIMIT). Optional
    # client stop so pathological RPS does not grow count unboundedly in memory.
    SAMPLE_COUNT_LIMIT = 1_000_000

    def initialize(ttl: 60)
      @metrics = {}
      @mutex = Mutex.new
      @ttl = ttl
    end

    # Records a sample. Strategy-default write rule:
    # - rqt: accumulate sum+count for the current Unix second
    # - everything else: latest-wins bare Numeric
    # Non-finite / non-Numeric values are ignored (defense in depth).
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

    # Clears samples inherited across a fork (parent CPU/job-queue state). Any RQT already
    # recorded on the child's first request before {Dispatcher#start} is also dropped —
    # one sample is negligible compared to a simpler, complete reset.
    #
    # Prefer {#reinit_after_fork} in the child: it replaces the mutex so a lock held at
    # +Process._fork+ cannot deadlock the child.
    def discard_inherited
      @mutex.synchronize { @metrics = {} }
    end

    # Child-side fork reset: new mutex + empty metrics. Must not lock the inherited
    # mutex (it may be stuck if the parent held it across fork).
    def reinit_after_fork
      @mutex = Mutex.new
      @metrics = {}
    end

    # Re-insert previously flushed rqt buckets ({sum, count} per second). Merges
    # with any live bucket for the same second by adding sum and count. Caps at
    # SAMPLE_COUNT_LIMIT (same as sample) so wire weight stays honest with mean.
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
        # Keep mean: scale sum to the capped count so mean * n stays consistent.
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
