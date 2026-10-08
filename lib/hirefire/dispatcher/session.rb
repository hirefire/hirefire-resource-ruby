# frozen_string_literal: true

require "json"

module HireFire
  class Dispatcher
    class Session
      def initialize(configuration)
        @configuration = configuration
        @client = Client.new
        @lease = Lease.new
        @mutex = Mutex.new
        @wake = Thread::ConditionVariable.new
        @live = true
        @handoff = false
        @dispatch_thread = nil
        @lease_thread = nil
        @sample_thread = nil
        @dispatch_frequency = DEFAULT_DISPATCH_FREQUENCY
        @next_dispatch_at = nil
        @last_rqt_second = nil
        @pending_sample_trace = nil
        @round_started_at = nil
        @failures = 0
        @failure_logged_at = nil
        @unloaded_adapter_warned = {}
        @plan_override_warned = {}
        @unknown_adapter_warned = {}
        @unsupported_strategy_warned = {}
        @unknown_strategy_warned = {}
        @empty_queues_warned = {}
      end

      def start
        @dispatch_thread = spawn("hirefire-dispatch") { dispatch_loop }
        self
      end

      def live?
        @live
      end

      def alive?
        @live && !!@dispatch_thread&.alive?
      end

      def halt(handoff: false)
        @mutex.synchronize do
          @live = false
          @handoff = handoff
          @wake.broadcast
        end
      end

      def join(timeout)
        thread = @dispatch_thread
        thread.nil? || !!thread.join(timeout)
      end

      def close
        @client.close
      end

      def report
        guard { configuration.active_cpu_sources.each { |source| guard { source.sample } } }
        dispatch_if_due
      end

      def renew
        if round_overdue?
          release_overdue_round
        else
          @lease.request_if_due(hold: method(:hold_lease?))
        end
      end

      def sample
        @lease.sample_if_due do
          @round_started_at = Clock.monotonic
          sample_job_queues
        ensure
          @round_started_at = nil
        end
      end

      def flush
        dispatch(final: true)
      end

      private

      def spawn(name, &body)
        Thread.new(&body).tap { |thread| thread.name = name }
      end

      def dispatch_loop
        cycle do
          ensure_lease_loop
          report
        end
      ensure
        guard { @client.close } unless @handoff
      end

      def lease_loop
        cycle do
          renew
          ensure_sample_loop if @lease.granted?
        end
      ensure
        guard { @lease.close }
      end

      def sample_loop
        while sampling?
          guard { sample }
          pause
        end
      ensure
        guard { Plan.release_macros }
      end

      def cycle
        while @live
          guard { yield }
          pause
        end
      end

      def pause
        @mutex.synchronize { @wake.wait(@mutex, TICK) if @live }
      end

      def guard
        yield
      rescue Exception => e # standard:disable Lint/RescueException
        Log.safe(logger, :error, "[HireFire] #{Log.format_error(e)}")
      end

      def ensure_lease_loop
        return if @lease_thread&.alive? || !enter_race?

        @lease_thread = spawn("hirefire-lease") { lease_loop }
      end

      def ensure_sample_loop
        return if @sample_thread&.alive?

        @sample_thread = spawn("hirefire-sample") { sample_loop }
      end

      def sampling?
        @live && @lease.granted?
      end

      def round_overdue?
        started = @round_started_at
        !started.nil? && Clock.monotonic - started > SAMPLE_ROUND_LIMIT
      end

      def release_overdue_round
        return unless @lease.granted?

        @lease.demote!
        Log.safe(logger, :warn, "[HireFire] A job queue sample round has run for more than " \
          "#{SAMPLE_ROUND_LIMIT} seconds. The lease is released so that another process can sample.")
      end

      def enter_race?
        configuration.job_queues.any? || Plan.any_allowlisted_job_queue_library_loaded?
      end

      def hold_lease?(plan_job_queues)
        return true if configuration.job_queues.any?

        plan_job_queues.any? do |entry|
          adapter_present?(entry) && Plan.sampleable_entry?(entry)
        end
      end

      def sample_job_queues
        live = method(:sampling?)
        probe = Probe.start
        Plan.around_job_queue_sample do
          local_job_queues = configuration.job_queues

          @lease.job_queues.each do |entry|
            break unless live.call

            probe.measure(entry) do
              if adapter_present?(entry)
                sample_plan_adapter(entry, local_job_queues, live)
              else
                sample_strategy_only(entry, local_job_queues, live)
              end
            end
          end
        end
        payload = probe.finish
        probe.log_to(logger) if verbose?
        @pending_sample_trace = payload if @lease.trace?
      end

      def verbose?
        value = ENV["HIREFIRE_VERBOSE"].to_s
        !value.empty? && !%w[0 false no].include?(value.downcase)
      end

      def sample_plan_adapter(entry, local_job_queues, live)
        name = entry["name"].to_s
        adapter = entry["adapter"]
        strategy = entry["strategy"]

        if Plan.executable?(adapter)
          unless Plan.supports_strategy?(adapter, strategy)
            warn_unsupported_strategy_once(name, adapter, strategy)
            return
          end

          if Plan.queues_required?(adapter) && !Plan.named_plan_queues?(entry["queues"])
            warn_empty_queues_once(name, adapter)
            return
          end

          warn_plan_override_once(name) if local_job_queues.find_by_name(name)
          Plan.execute(entry, live)
        elsif Plan.known_adapter?(adapter)
          warn_unloaded_adapter_once(name, adapter)
        else
          warn_unknown_adapter_once(name, adapter)
        end
      end

      def sample_strategy_only(entry, local_job_queues, live)
        name = entry["name"].to_s
        strategy = entry["strategy"].to_s

        unless Plan.known_strategy?(strategy)
          warn_unknown_strategy_once(name, strategy)
          return
        end

        job_queue = local_job_queues.find_by_name(name)
        local_job_queues.sample_job_queue(job_queue, strategy, live: live, name: name.strip) if job_queue
      end

      def remember_warn(map, key)
        return true if map[key]

        map.shift while map.size >= WARN_MAP_LIMIT
        map[key] = true
        false
      end

      def warn_unloaded_adapter_once(name, adapter)
        return if remember_warn(@unloaded_adapter_warned, name)

        Log.safe(logger, :error, "[HireFire] Plan adapter #{adapter.inspect} for #{name.inspect} " \
          "is not loaded in this process. Entry skipped.")
      end

      def warn_plan_override_once(name)
        return if remember_warn(@plan_override_warned, name)

        Log.safe(logger, :warn, "[HireFire] A HireFire UI adapter is configured for " \
          "#{name.inspect}, so config.dyno(#{name.inspect}) with a local sampler is ignored. " \
          "You can remove that local configuration. The UI adapter is used instead.")
      end

      def warn_unknown_adapter_once(name, adapter)
        return if remember_warn(@unknown_adapter_warned, name)

        Log.safe(logger, :error, "[HireFire] Unknown plan adapter " \
          "#{adapter.inspect} for #{name.inspect}. Entry skipped.")
      end

      def warn_unsupported_strategy_once(name, adapter, strategy)
        return if remember_warn(@unsupported_strategy_warned, "#{name}\0#{adapter}\0#{strategy}")

        Log.safe(logger, :error, "[HireFire] Plan adapter #{adapter.inspect} does not support " \
          "strategy #{strategy.inspect} for #{name.inspect}. Entry skipped.")
      end

      def warn_unknown_strategy_once(name, strategy)
        return if remember_warn(@unknown_strategy_warned, "#{name}\0#{strategy}")

        Log.safe(logger, :error, "[HireFire] Unknown plan strategy #{strategy.inspect} for " \
          "#{name.inspect}. Entry skipped.")
      end

      def warn_empty_queues_once(name, adapter)
        return if remember_warn(@empty_queues_warned, "#{name}\0#{adapter}")

        Log.safe(logger, :error, "[HireFire] Plan adapter #{adapter.inspect} for #{name.inspect} " \
          "requires named queues. Entry skipped.")
      end

      def adapter_present?(entry)
        adapter = entry["adapter"]
        !(adapter.nil? || adapter == "")
      end

      def dispatch_if_due
        return if @next_dispatch_at && Clock.monotonic < @next_dispatch_at

        dispatch
        @next_dispatch_at = Clock.monotonic + dispatch_interval
      end

      def dispatch_interval
        return @dispatch_frequency if @failures.zero?

        [@dispatch_frequency * 2**[@failures, BACKOFF_DOUBLINGS].min, MAX_DISPATCH_FREQUENCY].min
      end

      def dispatch(final: false)
        return unless final || @live

        data = buffer.flush
        payload, watermark = build_payload(data)
        return if payload.empty?

        body = JSON.generate(payload)
        if body.bytesize > PAYLOAD_SIZE_LIMIT && payload_has_sample_trace?(payload)
          payload = strip_sample_trace(payload)
          body = JSON.generate(payload)
        end
        return drop_oversized_payload(body, watermark) if body.bytesize > PAYLOAD_SIZE_LIMIT

        Log.safe(logger, :info, "[HireFire] Dispatching metrics: #{body}") if verbose?
        response = @client.submit_samples(body)

        if response == :payload_too_large
          drop_oversized_payload(body, watermark, server: true)
        else
          apply_dispatch_frequency(response)
          @last_rqt_second = watermark if watermark
          @pending_sample_trace = nil
        end
        dispatch_succeeded
      rescue => e
        repopulate_rqt(data) if data && (final || @live || @handoff)
        dispatch_failed(e)
      end

      def dispatch_succeeded
        if @failures > 1
          Log.safe(logger, :info, "[HireFire] Dispatch recovered after #{@failures} failed attempts.")
        end
        @failures = 0
        @failure_logged_at = nil
      end

      def dispatch_failed(error)
        @failures += 1
        now = Clock.monotonic
        return if @failure_logged_at && now - @failure_logged_at < FAILURE_LOG_INTERVAL

        @failure_logged_at = now
        attempts = " (#{@failures} failed attempts in a row)" if @failures > 1
        Log.safe(logger, :error, "[HireFire] Dispatch error: #{Log.format_error(error)}#{attempts}")
      end

      def repopulate_rqt(data)
        data.each do |name, strategies|
          buckets = strategies[Strategy::RQT]
          buffer.repopulate(name, Strategy::RQT, buckets) if buckets&.any?
        end
      end

      def apply_dispatch_frequency(response)
        value = Client.header_integer(response, "HireFire-Dispatch-Frequency") if response
        @dispatch_frequency = value.clamp(DEFAULT_DISPATCH_FREQUENCY, MAX_DISPATCH_FREQUENCY) if value
      end

      def drop_oversized_payload(body, watermark, server: false)
        @pending_sample_trace = nil
        @last_rqt_second = watermark if watermark
        source = server ? "server rejected (413)" : "exceeds the #{PAYLOAD_SIZE_LIMIT}-byte limit"
        Log.safe(logger, :error, "[HireFire] Dropped metrics payload: #{body.bytesize} bytes " \
          "#{source}. Resuming from the current second.")
      end

      def payload_has_sample_trace?(payload)
        payload.first.key?("sample_trace")
      end

      def strip_sample_trace(payload)
        @pending_sample_trace = nil
        [payload.first.except("sample_trace"), *payload.drop(1)]
      end

      def build_payload(data)
        http_name = configuration.http_name
        series = {}
        watermark = nil

        if http_name && configuration.rqt_enabled?
          claimed = backfill_rqt_seconds(data.dig(http_name, Strategy::RQT) || {})
          series[http_name] = {Strategy::RQT => claimed}
          watermark = claimed.keys.max
        end

        data.each do |name, strategies|
          strategies.each do |strategy, buckets|
            (series[name] ||= {})[strategy] ||= buckets
          end
        end

        entries = series.filter_map do |name, strategies|
          metrics = strategies.filter_map do |strategy, buckets|
            leaves = encode_series(strategy, buckets)
            [strategy, leaves] unless leaves.empty?
          end
          {"name" => name, "metrics" => metrics.to_h} unless metrics.empty?
        end

        entries.first["sample_trace"] = @pending_sample_trace if entries.any? && @pending_sample_trace && @lease.trace?
        [entries, watermark]
      end

      def backfill_rqt_seconds(buckets)
        now = Time.now.to_i
        from = (@last_rqt_second ? @last_rqt_second + 1 : now).clamp(now - RQT_BACKFILL_LIMIT, now)
        (from..now).each_with_object(buckets.dup) { |second, claimed| claimed[second] ||= Buffer::EMPTY_BUCKET }
      end

      def encode_series(strategy, buckets)
        buckets.each_with_object({}) do |(second, bucket), leaves|
          leaf = Strategy.rqt?(strategy) ? rqt_leaf(bucket) : value_leaf(bucket)
          if leaf
            leaves[second.to_s] = leaf
          else
            Log.safe(logger, :error, "[HireFire] Omitting #{strategy} second: out-of-range value.")
          end
        end
      end

      def rqt_leaf(bucket)
        return [] if bucket[:count].zero?

        mean = value_leaf(bucket[:sum] / bucket[:count])
        [mean, bucket[:count]] if mean
      end

      def value_leaf(value)
        value if value.between?(0, METRIC_VALUE_LIMIT)
      end

      def buffer
        configuration.buffer
      end

      attr_reader :configuration

      def logger
        configuration.logger
      end
    end
  end
end
