# frozen_string_literal: true

module HireFire
  # Periodic reporter that samples job queues and CPU and flushes buffered metrics to the API.
  class Dispatcher
    RQT_BACKFILL_LIMIT = 60
    PAYLOAD_SIZE_LIMIT = 32_768
    SAMPLE_COUNT_LIMIT = Buffer::SAMPLE_COUNT_LIMIT
    METRIC_VALUE_LIMIT = 1e15
    DEFAULT_DISPATCH_FREQUENCY = 1
    MAX_DISPATCH_FREQUENCY = 30
    # Bound how long {#stop} waits for each loop thread. A hung job-queue sampler can
    # outlive this; the thread is abandoned (not killed) so a mid-mutex kill cannot
    # deadlock final flush/close. MRI terminates leftover threads when the process exits.
    JOIN_TIMEOUT = 5

    def initialize
      @client = Client.new
      @lease = Lease.new
      @mutex = Mutex.new
      @running = false
      @stopping = false
      @pid = nil
      @generation = 0
      @thread = nil
      @job_queue_thread = nil
      @last_rqt_second = nil
      @dispatch_frequency = DEFAULT_DISPATCH_FREQUENCY
      @next_dispatch_at = nil
      @unloaded_adapter_warned = {}
      @plan_override_warned = {}
      @unknown_adapter_warned = {}
      @unsupported_strategy_warned = {}
    end

    # Starts the dispatcher loops.
    #
    # @return [Boolean] +true+ when started. +false+ if already running in this process, or if
    #   starting the loops failed (the failure is logged).
    def start
      return false if @running && @pid == Process.pid && !@stopping

      @mutex.synchronize do
        return false if @stopping
        return false if @running && @pid == Process.pid

        after_fork = @pid && @pid != Process.pid
        if after_fork
          buffer.discard_inherited
          reset_dispatch_state_after_fork
        end

        @generation += 1
        generation = @generation
        @thread = Thread.new { loop_until_stopped(generation) { tick } }
        @job_queue_thread = Thread.new { loop_until_stopped(generation) { job_queue_tick } } if enter_race?
        @running = true
        @pid = Process.pid
      end

      Log.safe(logger, :info, "[HireFire] Starting dispatcher.")

      true
    rescue => e
      Log.safe(logger, :error, "[HireFire] Could not start dispatcher: #{e.message}")
      false
    end

    # Ensures the job-queue loop is running when lease race entry becomes true after a late configure.
    #
    # @return [void]
    def ensure_job_queue_loop
      return if @job_queue_thread&.alive? && @running && @pid == Process.pid && !@stopping

      @mutex.synchronize do
        return if @stopping
        return unless @running && @pid == Process.pid
        return if @job_queue_thread&.alive?
        return unless enter_race?

        generation = @generation
        @job_queue_thread = Thread.new { loop_until_stopped(generation) { job_queue_tick } }
      end
    rescue => e
      Log.safe(logger, :error, "[HireFire] Could not start job-queue loop: #{e.message}")
    end

    # Stops the dispatcher loops and closes transport resources.
    #
    # Joins local loop threads for up to {JOIN_TIMEOUT} seconds each. A hung sampler is abandoned
    # (not {Thread#kill}'d) so a kill mid-mutex cannot deadlock flush/close. Loop generations
    # prevent an abandoned thread from resuming work after a later {#start}. A +@stopping+ gate
    # rejects concurrent {#start} until close finishes.
    #
    # @param flush [Boolean] when +true+ (default), best-effort final metric flush before close.
    #   Prefork parents pass +false+ so the master does not claim empty web liveness after workers
    #   take over.
    # @return [Boolean] +true+ once the dispatcher has stopped, +false+ when it was not running.
    def stop(flush: true)
      threads = nil

      @mutex.synchronize do
        return false unless @running
        return false if @stopping

        @stopping = true
        @running = false
        threads = [@thread, @job_queue_thread].compact if @pid == Process.pid
        @thread = nil
        @job_queue_thread = nil
        @pid = nil
      end

      begin
        threads&.each { |thread| join_loop_thread(thread) }

        dispatch if flush

        @client.close
        @lease.close

        Log.safe(logger, :info, "[HireFire] Dispatcher stopped.")

        true
      ensure
        @mutex.synchronize { @stopping = false }
      end
    end

    # Whether the dispatcher is currently running in this process.
    #
    # @return [Boolean]
    def running?
      @mutex.synchronize { @running && !@stopping && @pid == Process.pid }
    end

    private

    # --- lifecycle / loops ----------------------------------------------------

    def loop_active?(generation)
      @mutex.synchronize { @running && !@stopping && @pid == Process.pid && @generation == generation }
    end

    def loop_until_stopped(generation)
      while loop_active?(generation)
        yield
        sleep 1
      end
    end

    # Join a loop thread with a hard timeout. Do not kill: a Thread#kill while holding a
    # HireFire or Net::HTTP mutex can deadlock the final flush/close on this stop path.
    def join_loop_thread(thread)
      return if thread.join(JOIN_TIMEOUT)

      Log.safe(logger, :warn,
        "[HireFire] Dispatcher loop did not stop within #{JOIN_TIMEOUT}s. Abandoning thread.")
    end

    def tick
      configuration.active_cpu_sources.each { |source| guard { source.sample } }
      dispatch_if_due
    end

    # Spawned only when {#enter_race?} is true ({#start} / {#ensure_job_queue_loop}).
    def job_queue_tick
      guard { @lease.request_if_due(hold: method(:hold_lease?)) }
      guard { @lease.sample_if_due { sample_job_queues } }
    end

    def reset_dispatch_state_after_fork
      @next_dispatch_at = nil
      @last_rqt_second = nil
      @dispatch_frequency = DEFAULT_DISPATCH_FREQUENCY
      @unloaded_adapter_warned = {}
      @plan_override_warned = {}
      @unknown_adapter_warned = {}
      @unsupported_strategy_warned = {}
      configuration.reset_after_fork
    end

    # --- lease race / job-queue sampling --------------------------------------

    # Enter the race when this process might sample job queues (local dynos or an
    # allowlisted library is loaded). Holding the grant is separate — see {#hold_lease?}.
    def enter_race?
      configuration.job_queues.any? || Plan.any_allowlisted_job_queue_library_loaded?
    end

    # Keep the grant only when this process can actually sample: local job queues, or at
    # least one plan entry with an executable adapter that supports the plan strategy.
    def hold_lease?(plan_job_queues)
      return true if configuration.job_queues.any?

      plan_job_queues.any? do |entry|
        adapter_present?(entry) &&
          Plan.executable?(entry["adapter"]) &&
          Plan.supports_strategy?(entry["adapter"], entry["strategy"])
      end
    end

    def sample_job_queues
      local_job_queues = configuration.job_queues

      @lease.job_queues.each do |entry|
        if adapter_present?(entry)
          sample_plan_adapter(entry, local_job_queues)
        else
          sample_strategy_only(entry, local_job_queues)
        end
      end
    end

    def sample_plan_adapter(entry, local_job_queues)
      name = entry["name"].to_s
      adapter = entry["adapter"]
      strategy = entry["strategy"]

      if Plan.executable?(adapter)
        unless Plan.supports_strategy?(adapter, strategy)
          warn_unsupported_strategy_once(name, adapter, strategy)
          return
        end

        warn_plan_override_once(name) if local_job_queues.find_by_name(name)
        Plan.execute(entry)
      elsif Plan.known_adapter?(adapter)
        warn_unloaded_adapter_once(name, adapter)
      else
        warn_unknown_adapter_once(name, adapter)
      end
    end

    def sample_strategy_only(entry, local_job_queues)
      name = entry["name"].to_s
      strategy = entry["strategy"].to_s

      unless Plan.known_strategy?(strategy)
        Log.safe(logger, :error, "[HireFire] Unknown plan strategy #{strategy.inspect} for " \
          "#{name.inspect}. Entry skipped.")
        return
      end

      job_queue = local_job_queues.find_by_name(name)
      local_job_queues.sample_job_queue(job_queue, strategy) if job_queue
    end

    def warn_unloaded_adapter_once(name, adapter)
      return if @unloaded_adapter_warned[name]

      @unloaded_adapter_warned[name] = true
      Log.safe(logger, :error, "[HireFire] Plan adapter #{adapter.inspect} for #{name.inspect} " \
        "is not loaded in this process. Entry skipped.")
    end

    def warn_plan_override_once(name)
      return if @plan_override_warned[name]

      @plan_override_warned[name] = true
      Log.safe(logger, :info, "[HireFire] Lease plan overrides the local sampler for " \
        "#{name.inspect}. The local sampler is ignored for this name.")
    end

    def warn_unknown_adapter_once(name, adapter)
      return if @unknown_adapter_warned[name]

      @unknown_adapter_warned[name] = true
      Log.safe(logger, :error, "[HireFire] Unknown plan adapter " \
        "#{adapter.inspect} for #{name.inspect}. Entry skipped.")
    end

    def warn_unsupported_strategy_once(name, adapter, strategy)
      key = "#{name}\0#{adapter}\0#{strategy}"
      return if @unsupported_strategy_warned[key]

      @unsupported_strategy_warned[key] = true
      Log.safe(logger, :error, "[HireFire] Plan adapter #{adapter.inspect} does not support " \
        "strategy #{strategy.inspect} for #{name.inspect}. Entry skipped.")
    end

    def adapter_present?(entry)
      adapter = entry["adapter"]
      !(adapter.nil? || adapter == "")
    end

    # --- dispatch / payload ---------------------------------------------------

    def dispatch_if_due
      return if @next_dispatch_at && Clock.monotonic < @next_dispatch_at

      dispatch
      @next_dispatch_at = Clock.monotonic + @dispatch_frequency
    end

    def guard
      yield
    rescue => e
      Log.safe(logger, :error, "[HireFire] #{e.message}")
    end

    def dispatch
      data = buffer.flush
      payload, watermark = build_payload(data)
      return if payload.empty?

      body = JSON.generate(payload)
      return drop_oversized_payload(body, watermark) if body.bytesize > PAYLOAD_SIZE_LIMIT

      Log.safe(logger, :info, "[HireFire] Dispatching metrics: #{body}") if ENV["HIREFIRE_VERBOSE"]
      response = @client.submit_samples(body)

      case response
      when :payload_too_large
        drop_oversized_payload(body, watermark, server: true)
      else
        # 2xx → response object; 401 → nil. Both advance watermark, no repopulate.
        apply_dispatch_frequency(response)
        @last_rqt_second = watermark if watermark
      end
    rescue => e
      # Reclaim only rqt so RPM/liveness can recover. Other strategies are re-sampled next cycle.
      # Pre-encode buckets only (never synthetic backfill empties).
      repopulate_rqt(data) if data
      Log.safe(logger, :error, "[HireFire] Dispatch error: #{e.message}")
    end

    def repopulate_rqt(data)
      data.each do |name, strategies|
        series = strategies["rqt"]
        next unless series&.any?

        buffer.repopulate(name, "rqt", series)
      end
    end

    def apply_dispatch_frequency(response)
      return unless response.respond_to?(:key?) && response.key?("HireFire-Dispatch-Frequency")

      value = response["HireFire-Dispatch-Frequency"].to_i
      return unless value.positive?

      @dispatch_frequency = value.clamp(DEFAULT_DISPATCH_FREQUENCY, MAX_DISPATCH_FREQUENCY)
    end

    def drop_oversized_payload(body, watermark, server: false)
      @last_rqt_second = watermark if watermark
      source = server ? "server rejected (413)" : "exceeds the #{PAYLOAD_SIZE_LIMIT}-byte limit"
      Log.safe(logger, :error, "[HireFire] Dropped metrics payload: #{body.bytesize} bytes " \
        "#{source}. Resuming from the current second.")
    end

    def build_payload(data)
      entries_by_name = {}
      http_name = configuration.http_name
      watermark = append_http_rqt!(entries_by_name, data, http_name)

      data.each do |name, strategies|
        strategies.each do |strategy, series|
          strategy = strategy.to_s
          next if series.nil? || series.empty?
          next if strategy == "rqt" && name == http_name

          merge_metrics(entries_by_name, name, strategy, series)
        end
      end

      entries = []
      entries_by_name.each do |name, metrics|
        encoded = {}
        metrics.each do |strategy, series|
          strategy_key = strategy.to_s
          leaf_series = {}
          series.each do |second, bucket|
            leaf = encode_leaf(strategy_key, bucket)
            next if leaf == :omit

            leaf_series[second.to_s] = leaf
          end
          encoded[strategy_key] = leaf_series unless leaf_series.empty?
        end
        next if encoded.empty?

        entries << {"name" => name, "metrics" => encoded}
      end

      [entries, watermark]
    end

    # HTTP process rqt: liveness backfill when enabled (sets watermark); otherwise flush
    # real samples only. Non-http rqt and all other strategies are merged by the caller.
    def append_http_rqt!(entries_by_name, data, http_name)
      return nil unless http_name

      rqt_buckets = data.dig(http_name, "rqt") || data.dig(http_name, :rqt) || {}

      if configuration.rqt_enabled? && configuration.rqt_liveness?
        payload_rqt = backfill_rqt_seconds(rqt_buckets)
        merge_metrics(entries_by_name, http_name, "rqt", payload_rqt)
        payload_rqt.keys.max
      elsif rqt_buckets.any?
        merge_metrics(entries_by_name, http_name, "rqt", rqt_buckets)
        nil
      end
    end

    # Strategy-aware merge of flushed buckets into the payload-side map.
    def merge_metrics(entries_by_name, name, strategy, series_buckets)
      strategy = strategy.to_s
      entries_by_name[name] ||= {}
      entries_by_name[name][strategy] ||= {}
      dest = entries_by_name[name][strategy]

      series_buckets.each do |second, bucket|
        if strategy == "rqt"
          if dest[second].nil?
            dest[second] = copy_rqt_bucket(bucket)
          else
            sum, count = rqt_parts(bucket)
            dest[second] = {
              sum: dest[second][:sum] + sum,
              count: dest[second][:count] + count
            }
          end
        else
          dest[second] = bucket
        end
      end
    end

    def copy_rqt_bucket(bucket)
      sum, count = rqt_parts(bucket)
      {sum: sum, count: count}
    end

    def rqt_parts(bucket)
      case bucket
      when Hash
        sum = bucket[:sum] || bucket["sum"]
        count = bucket[:count] || bucket["count"]
        [sum.to_f, count.to_i]
      when nil
        [0.0, 0]
      else
        [0.0, 0]
      end
    end

    # Encode a buffer bucket into a wire leaf.
    # rqt: [] heartbeat or [mean, n]. Non-rqt: bare number.
    # Returns :omit to skip a non-finite / out-of-range value.
    def encode_leaf(strategy, bucket)
      if strategy == "rqt"
        sum, count = rqt_parts(bucket)
        return [] if count == 0

        mean = sum / count
        unless mean.finite? && mean.between?(0, METRIC_VALUE_LIMIT)
          Log.safe(logger, :error, "[HireFire] Omitting rqt second: non-finite or out-of-range mean.")
          return :omit
        end

        n = count
        n = SAMPLE_COUNT_LIMIT if n > SAMPLE_COUNT_LIMIT
        [mean, n]
      else
        return :omit unless bucket.is_a?(Numeric)
        return :omit unless bucket.finite? && bucket.between?(0, METRIC_VALUE_LIMIT)

        bucket
      end
    end

    # Payload-only backfill: missing seconds become empty {sum, count} buckets.
    # Never writes into the live buffer. Synthetic empties are not in flush data
    # and are therefore not repopulated on failure.
    def backfill_rqt_seconds(buckets)
      now = Time.now.to_i
      from = @last_rqt_second ? @last_rqt_second + 1 : now
      from = now - RQT_BACKFILL_LIMIT if from < now - RQT_BACKFILL_LIMIT
      from = now if from > now

      payload = {}
      buckets.each do |second, bucket|
        payload[second] = copy_rqt_bucket(bucket)
      end
      (from..now).each do |second|
        payload[second] ||= {sum: 0.0, count: 0}
      end
      payload
    end

    # --- accessors ------------------------------------------------------------

    def buffer
      HireFire.configuration.buffer
    end

    def configuration
      HireFire.configuration
    end

    def logger
      configuration.logger
    end
  end
end
