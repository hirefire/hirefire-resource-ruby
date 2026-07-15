# frozen_string_literal: true

module HireFire
  class Dispatcher
    WEB_BACKFILL_LIMIT = 60
    PAYLOAD_SIZE_LIMIT = 65_536
    DEFAULT_DISPATCH_FREQUENCY = 1
    MAX_DISPATCH_FREQUENCY = 30

    def initialize(web: nil, workers: Workers.new, cpu: [], web_liveness: true)
      @web = web
      @workers = workers
      @cpu = cpu
      @web_liveness = web_liveness
      @client = Client.new
      @lease = Lease.new(enabled: workers.any?)
      @mutex = Mutex.new
      @running = false
      @pid = nil
      @generation = 0
      @thread = nil
      @worker_thread = nil
      @last_web_second = nil
      @dispatch_frequency = DEFAULT_DISPATCH_FREQUENCY
      @next_dispatch_at = nil
    end

    def start
      return false if @running && @pid == Process.pid

      @mutex.synchronize do
        return false if @running && @pid == Process.pid

        buffer.discard_inherited if @pid && @pid != Process.pid

        @generation += 1
        generation = @generation
        @thread = Thread.new { loop_until_stopped(generation) { tick } }
        @worker_thread = Thread.new { loop_until_stopped(generation) { worker_tick } } if @workers.any?
        @running = true
        @pid = Process.pid
      end

      Log.safe(logger, :info, "[HireFire] Starting dispatcher.")

      true
    rescue => e
      Log.safe(logger, :error, "[HireFire] Could not start dispatcher: #{e.message}")
      false
    end

    def stop
      threads = nil

      @mutex.synchronize do
        return false unless @running

        @running = false
        threads = [@thread, @worker_thread].compact if @pid == Process.pid
        @thread = nil
        @worker_thread = nil
        @pid = nil
      end

      threads&.each { |thread| thread.join(5) }

      dispatch

      @client.close
      @lease.close

      Log.safe(logger, :info, "[HireFire] Dispatcher stopped.")

      true
    end

    def running?
      @mutex.synchronize { @running && @pid == Process.pid }
    end

    private

    def loop_active?(generation)
      @mutex.synchronize { @running && @pid == Process.pid && @generation == generation }
    end

    def loop_until_stopped(generation)
      while loop_active?(generation)
        yield
        sleep 1
      end
    end

    def tick
      @cpu.each { |collector| guard { collector.sample } }
      dispatch_if_due
    end

    def worker_tick
      guard { @lease.request_if_due }
      guard { @lease.sample_if_due { @workers.sample } }
    end

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
      apply_dispatch_frequency(response)
      @last_web_second = watermark if watermark
    rescue => e
      buffer.repopulate_web(data[:web]) if data && data[:web].any?
      Log.safe(logger, :error, "[HireFire] Dispatch error: #{e.message}")
    end

    def apply_dispatch_frequency(response)
      return unless response.respond_to?(:key?) && response.key?("HireFire-Dispatch-Frequency")

      value = response["HireFire-Dispatch-Frequency"].to_i
      return unless value.positive?

      @dispatch_frequency = value.clamp(DEFAULT_DISPATCH_FREQUENCY, MAX_DISPATCH_FREQUENCY)
    end

    def drop_oversized_payload(body, watermark)
      @last_web_second = watermark if watermark
      Log.safe(logger, :error, "[HireFire] Dropped metrics payload: #{body.bytesize} bytes exceeds " \
        "the #{PAYLOAD_SIZE_LIMIT}-byte limit. Resuming from the current second.")
    end

    def build_payload(data)
      entries = []
      watermark = nil

      if @web && @web_liveness
        samples = backfill_web_seconds(data[:web])
        watermark = samples.keys.max
        entries << {"name" => @web.name, "samples" => samples.transform_keys(&:to_s)}
      elsif @web && data[:web].any?
        entries << {"name" => @web.name, "samples" => data[:web].transform_keys(&:to_s)}
      end

      entries.concat(data[:workers])

      data[:cpu].each do |name, samples|
        entries << {"name" => name, "samples" => samples.transform_keys(&:to_s)}
      end

      [entries, watermark]
    end

    def backfill_web_seconds(samples)
      now = Time.now.to_i
      from = @last_web_second ? @last_web_second + 1 : now
      from = now - WEB_BACKFILL_LIMIT if from < now - WEB_BACKFILL_LIMIT
      from = now if from > now

      samples = samples.dup
      (from..now).each { |second| samples[second] ||= [] }
      samples
    end

    def buffer
      HireFire.configuration.buffer
    end

    def logger
      HireFire.configuration.logger
    end
  end
end
