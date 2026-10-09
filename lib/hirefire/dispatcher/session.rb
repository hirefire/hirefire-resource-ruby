# frozen_string_literal: true

require "json"
require_relative "payload"
require_relative "failure_log"

module HireFire
  class Dispatcher
    class Session
      def initialize(configuration)
        @configuration = configuration
        @client = Client.new(configuration)
        @lease = Lease.new(configuration)
        @mutex = Mutex.new
        @wake = Thread::ConditionVariable.new
        @live = true
        @handoff = false
        @ended = false
        @abandoned = false
        @dispatch_thread = nil
        @lease_thread = nil
        @sample_thread = nil
        @dispatch_frequency = DEFAULT_DISPATCH_FREQUENCY
        @next_dispatch_at = nil
        @last_rqt_second = nil
        @pending_sample_trace = nil
        @round_started_at = nil
        @dispatch_failures = FailureLog.new("Dispatch", configuration)
        @lease_failures = FailureLog.new("Lease request", configuration)
        @payload_drops = FailureLog.new("Metrics payload", configuration)
        @sampler = Sampler.new(configuration)
        @once = Once.new(configuration)
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
        !!@dispatch_thread.join(timeout)
      end

      def close
        @client.close
      end

      def abandon
        ended = @mutex.synchronize do
          @abandoned = true
          @ended
        end
        close if ended
      end

      def report
        guard { configuration.active_cpu_sources.each { |source| guard { source.sample } } }
        dispatch_if_due
      end

      def renew
        return release_overdue_round if round_overdue?

        @lease_failures.recovered if @lease.request_if_due(hold: @sampler.method(:can_sample?))
      rescue => e
        @lease_failures.failed(e)
      end

      def sample
        @lease.sample_if_due do
          @round_started_at = Clock.monotonic
          trace = @sampler.round(@lease.job_queues, method(:sampling?))
          @mutex.synchronize { @pending_sample_trace = trace }
        ensure
          @round_started_at = nil
        end
      end

      def flush
        dispatch(final: true)
      end

      private

      def spawn(name, &body)
        Thread.new(&body).tap do |thread|
          thread.name = name
          thread.thread_variable_set(:fork_safe, true)
        end
      end

      def dispatch_loop
        cycle do
          ensure_lease_loop
          report
        end
      ensure
        owned = @mutex.synchronize do
          @ended = true
          !@handoff || @abandoned
        end
        guard { @client.close } if owned
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
        guard { Plan.release_macros(logger) }
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
        configuration.job_queues.any? || Plan.any_library_loaded?
      end

      def dispatch_if_due
        return if @next_dispatch_at && Clock.monotonic < @next_dispatch_at

        dispatch
        @next_dispatch_at = Clock.monotonic + dispatch_interval
      end

      def dispatch_interval
        [@dispatch_frequency * 2**[@dispatch_failures.count, BACKOFF_DOUBLINGS].min, MAX_DISPATCH_FREQUENCY].min
      end

      def dispatch(final: false)
        return unless final || @live

        data = buffer.flush
        trace = @pending_sample_trace
        payload, watermark = build_payload(data, trace)
        return if payload.empty?

        body = encode(payload)
        return drop_oversized_payload(body, watermark, trace) if body.bytesize > PAYLOAD_SIZE_LIMIT

        submit(body, watermark, trace)
      rescue => e
        repopulate_rqt(data) if data && (@live || @handoff)
        @dispatch_failures.failed(e)
      end

      def encode(payload)
        body = JSON.generate(payload)
        return body unless body.bytesize > PAYLOAD_SIZE_LIMIT && Payload.traced?(payload)

        JSON.generate(Payload.without_trace(payload))
      end

      def submit(body, watermark, trace)
        Log.safe(logger, :info, "[HireFire] Dispatching metrics: #{body}") if Log.verbose?
        response = @client.submit_samples(body)
        apply_dispatch_frequency(response)

        if response.too_large?
          drop_oversized_payload(body, watermark, trace, server: true)
        else
          @last_rqt_second = watermark
          clear_trace(trace)
          @payload_drops.recovered
        end
        @dispatch_failures.recovered
      end

      def repopulate_rqt(data)
        data.each do |name, strategies|
          buckets = strategies[Strategy::RQT]
          buffer.repopulate(name, Strategy::RQT, buckets) if buckets&.any?
        end
      end

      def apply_dispatch_frequency(response)
        value = response.integer("HireFire-Dispatch-Frequency")
        @dispatch_frequency = value.clamp(DEFAULT_DISPATCH_FREQUENCY, MAX_DISPATCH_FREQUENCY) if value
      end

      def drop_oversized_payload(body, watermark, trace, server: false)
        clear_trace(trace)
        @last_rqt_second = watermark
        source = server ? "server rejected (413)" : "exceeds the #{PAYLOAD_SIZE_LIMIT}-byte limit"
        @payload_drops.record("Dropped metrics payload: #{body.bytesize} bytes " \
          "#{source}. Resuming from the current second.")
      end

      def clear_trace(sent)
        @mutex.synchronize { @pending_sample_trace = nil if @pending_sample_trace.equal?(sent) }
      end

      def build_payload(data, trace)
        liveness = configuration.http_name if configuration.rqt_enabled?
        trace = nil unless @lease.trace?

        Payload.build(data, liveness: liveness, since: @last_rqt_second, trace: trace) do |name, strategy|
          @once.log(:error, :out_of_range, [name, strategy]) do
            "[HireFire] Omitting #{strategy} seconds of #{name.inspect}: a value is out of range."
          end
        end
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
