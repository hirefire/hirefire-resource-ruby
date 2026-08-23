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
    JOIN_TIMEOUT = 5

    def initialize
      @client = Client.new
      @lease = Lease.new
      @mutex = Mutex.new
      @running = false
      @stopping = false
      @stopping_flush = false
      @pid = nil
      @generation = 0
      @thread = nil
      @job_queue_thread = nil
      @last_rqt_second = nil
      @dispatch_frequency = DEFAULT_DISPATCH_FREQUENCY
      @next_dispatch_at = nil
      @pending_sample_trace = nil
      @unloaded_adapter_warned = {}
      @plan_override_warned = {}
      @unknown_adapter_warned = {}
      @unsupported_strategy_warned = {}
      @unknown_strategy_warned = {}
    end

    # Starts the dispatcher loops.
    #
    # @return [Boolean] +true+ when started. +false+ if already running in this process, or if
    #   starting the loops failed (the failure is logged).
    def start
      return false if healthy_running?

      retired_jq = nil

      @mutex.synchronize do
        return false if @stopping
        return false if healthy_running_locked?

        if @running && @pid == Process.pid && !@thread&.alive?
          @running = false
          @thread = nil
          if @job_queue_thread&.alive?
            retired_jq = @job_queue_thread
            @job_queue_thread = nil
          end
        end

        after_fork = @pid && @pid != Process.pid
        if after_fork
          buffer.reinit_after_fork
          Plan.reinit_macros_after_fork
          reset_dispatch_state_after_fork
        end

        unless after_fork
          reset_dispatch_state_for_restart
          @lease.demote!
        end

        @generation += 1
        generation = @generation
        @thread = Thread.new { loop_until_stopped(generation) { tick(generation) } }
        if enter_race?
          @job_queue_thread = Thread.new { loop_until_stopped(generation) { job_queue_tick(generation) } }
        end
        @running = true
        @pid = Process.pid
      end

      join_loop_thread(retired_jq) if retired_jq

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
      return unless enter_race?

      @mutex.synchronize do
        return if @stopping
        return unless @running && @pid == Process.pid
        return if @job_queue_thread&.alive?
        return unless enter_race?

        generation = @generation
        @job_queue_thread = Thread.new { loop_until_stopped(generation) { job_queue_tick(generation) } }
      end
    rescue => e
      Log.safe(logger, :error, "[HireFire] Could not start job-queue loop: #{e.message}")
    end

    # Stops the dispatcher loops and closes transport resources.
    #
    # Joins local loop threads for up to {JOIN_TIMEOUT} seconds each. A hung sampler is abandoned
    # (not +Thread#kill+'d) so a kill mid-mutex cannot deadlock flush/close. Loop generations
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
        @stopping_flush = flush
        @running = false
        threads = [@thread, @job_queue_thread].compact if @pid == Process.pid
        @thread = nil
        @job_queue_thread = nil
        @pid = nil
      end

      begin
        threads&.each { |thread| join_loop_thread(thread) }

        if flush
          dispatch
        else
          buffer.discard_inherited
        end

        Log.safe(logger, :info, "[HireFire] Dispatcher stopped.")

        true
      ensure
        begin
          @client.close
        rescue => e
          Log.safe(logger, :error, "[HireFire] Client close error: #{e.message}")
        end
        begin
          @lease.demote!
          @lease.close
        rescue => e
          Log.safe(logger, :error, "[HireFire] Lease close error: #{e.message}")
        end
        @mutex.synchronize do
          @stopping = false
          @stopping_flush = false
        end
      end
    end

    # Whether the dispatcher is currently running in this process.
    #
    # @return [Boolean]
    def running?
      @mutex.synchronize { healthy_running_locked? }
    end

    # Child-side cleanup after a fork that does not restart reporting (job-only / Resque-style).
    # Clears inherited loop flags, buffer, and lease so +at_exit+ cannot flush the parent's
    # samples from the short-lived child.
    #
    # @return [void]
    def abandon_inherited_state!
      @mutex.synchronize do
        @running = false
        @stopping = false
        @stopping_flush = false
        @thread = nil
        @job_queue_thread = nil
        @pid = nil
        @generation += 1
      end
      buffer.reinit_after_fork
      Plan.reinit_macros_after_fork
      @lease.demote!
      @client.close
      @lease.close
    rescue => e
      Log.safe(logger, :error, "[HireFire] Could not abandon inherited dispatcher state: #{e.message}")
    end

    private

    def healthy_running?
      @running && !@stopping && @pid == Process.pid && @thread&.alive?
    end

    def healthy_running_locked?
      @running && !@stopping && @pid == Process.pid && @thread&.alive?
    end

    def loop_active?(generation)
      @mutex.synchronize { @running && !@stopping && @pid == Process.pid && @generation == generation }
    end

    def loop_until_stopped(generation)
      while loop_active?(generation)
        yield
        sleep 1
      end
    end

    def join_loop_thread(thread)
      return if thread.join(JOIN_TIMEOUT)

      Log.safe(logger, :warn,
        "[HireFire] Dispatcher loop did not stop within #{JOIN_TIMEOUT}s. Abandoning thread.")
    end

    def tick(generation = nil)
      return if generation && !loop_active?(generation)

      configuration.active_cpu_sources.each { |source| guard { source.sample } }
      dispatch_if_due(generation)
    end

    def job_queue_tick(generation = nil)
      live = loop_live_proc(generation)
      return unless live.call

      guard { @lease.request_if_due(hold: method(:hold_lease?)) }
      return unless live.call

      guard { @lease.sample_if_due { sample_job_queues(live: live) } }
    end

    def reset_dispatch_state_after_fork
      reset_dispatch_state_for_restart
      configuration.reset_after_fork
    end

    def reset_dispatch_state_for_restart
      @next_dispatch_at = nil
      @last_rqt_second = nil
      @dispatch_frequency = DEFAULT_DISPATCH_FREQUENCY
      @pending_sample_trace = nil
      @unloaded_adapter_warned = {}
      @plan_override_warned = {}
      @unknown_adapter_warned = {}
      @unsupported_strategy_warned = {}
      @unknown_strategy_warned = {}
    end

    def enter_race?
      configuration.job_queues.any? || Plan.any_allowlisted_job_queue_library_loaded?
    end

    def hold_lease?(plan_job_queues)
      return true if configuration.job_queues.any?

      plan_job_queues.any? do |entry|
        adapter_present?(entry) &&
          Plan.executable?(entry["adapter"]) &&
          Plan.supports_strategy?(entry["adapter"], entry["strategy"])
      end
    end

    def sample_job_queues(live: nil)
      wave = SampleTraceWave.start
      Plan.around_job_queue_sample do
        local_job_queues = configuration.job_queues

        @lease.job_queues.each do |entry|
          break if live && !live.call

          wave.measure(entry) do
            if adapter_present?(entry)
              sample_plan_adapter(entry, local_job_queues, live: live)
            else
              sample_strategy_only(entry, local_job_queues, live: live)
            end
          end
        end
      end
      payload = wave.finish
      wave.log_to(logger) if verbose?
      @pending_sample_trace = payload if @lease.trace?
    end

    def verbose?
      value = ENV["HIREFIRE_VERBOSE"].to_s
      !value.empty? && !%w[0 false no].include?(value.downcase)
    end

    def sample_plan_adapter(entry, local_job_queues, live: nil)
      return if live && !live.call

      name = entry["name"].to_s
      adapter = entry["adapter"]
      strategy = entry["strategy"]

      if Plan.executable?(adapter)
        unless Plan.supports_strategy?(adapter, strategy)
          warn_unsupported_strategy_once(name, adapter, strategy)
          return
        end

        warn_plan_override_once(name) if local_job_queues.find_by_name(name)
        return if live && !live.call

        Plan.execute(entry, live)
      elsif Plan.known_adapter?(adapter)
        warn_unloaded_adapter_once(name, adapter)
      else
        warn_unknown_adapter_once(name, adapter)
      end
    end

    def sample_strategy_only(entry, local_job_queues, live: nil)
      return if live && !live.call

      name = entry["name"].to_s
      strategy = entry["strategy"].to_s

      unless Plan.known_strategy?(strategy)
        warn_unknown_strategy_once(name, strategy)
        return
      end

      job_queue = local_job_queues.find_by_name(name)
      local_job_queues.sample_job_queue(job_queue, strategy, live: live, name: name.strip) if job_queue
    end

    def loop_live_proc(generation)
      if generation
        -> { loop_active?(generation) }
      else
        -> { true }
      end
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
      Log.safe(logger, :warn, "[HireFire] A HireFire UI adapter is configured for " \
        "#{name.inspect}, so config.dyno(#{name.inspect}) with a local sampler is ignored. " \
        "You can remove that local configuration; the UI adapter is used instead.")
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

    def warn_unknown_strategy_once(name, strategy)
      key = "#{name}\0#{strategy}"
      return if @unknown_strategy_warned[key]

      @unknown_strategy_warned[key] = true
      Log.safe(logger, :error, "[HireFire] Unknown plan strategy #{strategy.inspect} for " \
        "#{name.inspect}. Entry skipped.")
    end

    def adapter_present?(entry)
      adapter = entry["adapter"]
      !(adapter.nil? || adapter == "")
    end

    def dispatch_if_due(generation = nil)
      return if @next_dispatch_at && Clock.monotonic < @next_dispatch_at
      return if generation && !loop_active?(generation)

      dispatch(generation)
      if generation.nil? || loop_active?(generation)
        @next_dispatch_at = Clock.monotonic + @dispatch_frequency
      end
    end

    def guard
      yield
    rescue => e
      Log.safe(logger, :error, "[HireFire] #{e.class}: #{e.message}")
    end

    def dispatch(generation = nil)
      return if generation && !loop_active?(generation)

      data = buffer.flush
      payload, watermark = build_payload(data)
      return if payload.empty?

      body = JSON.generate(payload)
      if body.bytesize > PAYLOAD_SIZE_LIMIT
        return unless generation.nil? || loop_active?(generation) || handoff_to_final_flush?

        return drop_oversized_payload(body, watermark)
      end

      if generation && !loop_active?(generation)
        repopulate_rqt(data) if handoff_to_final_flush?
        return
      end

      Log.safe(logger, :info, "[HireFire] Dispatching metrics: #{body}") if verbose?
      response = @client.submit_samples(body)

      if generation && !loop_active?(generation)
        return
      end

      case response
      when :payload_too_large
        drop_oversized_payload(body, watermark, server: true)
      else
        apply_dispatch_frequency(response)
        @last_rqt_second = watermark if watermark
        @pending_sample_trace = nil
      end
    rescue => e
      if data && (generation.nil? || loop_active?(generation) || handoff_to_final_flush?)
        repopulate_rqt(data)
      end
      Log.safe(logger, :error, "[HireFire] Dispatch error: #{e.class}: #{e.message}")
    end

    def handoff_to_final_flush?
      @mutex.synchronize { @stopping && @stopping_flush }
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

      attach_sample_trace!(entries)
      [entries, watermark]
    end

    def attach_sample_trace!(entries)
      return if @pending_sample_trace.nil? || entries.empty? || !@lease.trace?

      entries.first["sample_trace"] = @pending_sample_trace
    end

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
        unless bucket.finite? && bucket.between?(0, METRIC_VALUE_LIMIT)
          Log.safe(logger, :error, "[HireFire] Omitting #{strategy} second: non-finite or out-of-range value.")
          return :omit
        end

        bucket
      end
    end

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
