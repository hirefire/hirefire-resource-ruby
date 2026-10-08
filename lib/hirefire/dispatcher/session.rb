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
        @next_dispatch_at = Clock.monotonic + @dispatch_frequency
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
      rescue => e
        repopulate_rqt(data) if data && (final || @live || @handoff)
        Log.safe(logger, :error, "[HireFire] Dispatch error: #{Log.format_error(e)}")
      end

      def repopulate_rqt(data)
        data.each do |name, strategies|
          series = strategies[Strategy::RQT]
          next unless series&.any?

          buffer.repopulate(name, Strategy::RQT, series)
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
        payload.first.is_a?(Hash) && payload.first.key?("sample_trace")
      end

      def strip_sample_trace(payload)
        @pending_sample_trace = nil
        payload.map do |entry|
          next entry unless entry.is_a?(Hash) && entry.key?("sample_trace")

          entry.dup.tap { |copy| copy.delete("sample_trace") }
        end
      end

      def build_payload(data)
        entries_by_name = {}
        http_name = configuration.http_name
        watermark = append_http_rqt!(entries_by_name, data, http_name)

        data.each do |name, strategies|
          strategies.each do |strategy, series|
            strategy = strategy.to_s
            next if series.nil? || series.empty?
            next if Strategy.rqt?(strategy) && name == http_name

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

        rqt_buckets = data.dig(http_name, Strategy::RQT) || {}

        if configuration.rqt_enabled? && configuration.rqt_liveness?
          payload_rqt = backfill_rqt_seconds(rqt_buckets)
          merge_metrics(entries_by_name, http_name, Strategy::RQT, payload_rqt)
          payload_rqt.keys.max
        elsif rqt_buckets.any?
          merge_metrics(entries_by_name, http_name, Strategy::RQT, rqt_buckets)
          nil
        end
      end

      def merge_metrics(entries_by_name, name, strategy, series_buckets)
        strategy = strategy.to_s
        entries_by_name[name] ||= {}
        entries_by_name[name][strategy] ||= {}
        dest = entries_by_name[name][strategy]

        series_buckets.each do |second, bucket|
          if Strategy.rqt?(strategy)
            if dest[second].nil?
              dest[second] = copy_rqt_bucket(bucket)
            else
              sum, count = Buffer.rqt_parts(bucket)
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
        sum, count = Buffer.rqt_parts(bucket)
        {sum: sum, count: count}
      end

      def encode_leaf(strategy, bucket)
        if Strategy.rqt?(strategy)
          sum, count = Buffer.rqt_parts(bucket)
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
        configuration.buffer
      end

      attr_reader :configuration

      def logger
        configuration.logger
      end
    end
  end
end
