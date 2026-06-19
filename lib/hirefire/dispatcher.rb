# frozen_string_literal: true

module HireFire
  class Dispatcher
    WEB_BACKFILL_LIMIT = 60

    # Mirrors the server's request body cap.
    PAYLOAD_SIZE_LIMIT = 65_536

    # Seconds between buffer dispatches; server-adjustable via the
    # HireFire-Dispatch-Frequency response header. Clamped to [1, 30].
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
      @last_web_second = nil
      @dispatch_frequency = DEFAULT_DISPATCH_FREQUENCY
      @next_dispatch_at = nil
    end

    # Fork-aware: a child inherits @running but not the thread, so the pid check
    # forces the per-request start to spawn a fresh thread.
    def start
      @mutex.synchronize do
        return false if @running && @pid == Process.pid

        @running = true
        @pid = Process.pid
        @thread = Thread.new do
          while running?
            tick
            sleep 1
          end
        end
      end

      logger.info "[HireFire] Starting dispatcher."

      true
    end

    def stop
      thread = nil

      @mutex.synchronize do
        return false unless @running

        @running = false
        # Only join a thread this process created (a forked child's handle is dead).
        thread = @thread if @pid == Process.pid
        @thread = nil
        @pid = nil
      end

      thread&.join(5)

      dispatch

      logger.info "[HireFire] Dispatcher stopped."

      true
    end

    def running?
      @mutex.synchronize { @running && @pid == Process.pid }
    end

    private

    # Stage-isolated so one failure can't starve dispatch, which drains the buffer.
    # Sampling runs every tick; only dispatch is throttled.
    def tick
      guard { @lease.request_if_due }
      guard { @lease.sample_if_due { @workers.sample } }
      @cpu.each { |collector| guard { collector.sample } }
      dispatch_if_due
    end

    # First run dispatches immediately; the next time is set after dispatch so a
    # just-learned frequency applies next tick. A guarded dispatch never raises, so
    # a failure still waits a full window.
    def dispatch_if_due
      return if @next_dispatch_at && Time.now < @next_dispatch_at

      dispatch
      @next_dispatch_at = Time.now + @dispatch_frequency
    end

    def guard
      yield
    rescue => e
      logger.error "[HireFire] #{e.message}"
    end

    def dispatch
      data = buffer.flush
      payload = build_payload(data)
      return if payload.empty?

      body = JSON.generate(payload)
      return drop_oversized_payload(body) if body.bytesize > PAYLOAD_SIZE_LIMIT

      logger.info "[HireFire] Dispatching metrics: #{body}" if ENV["HIREFIRE_VERBOSE"]
      response = @client.submit_samples(body)
      apply_dispatch_frequency(response)
      # Advance only after a successful submit; failed seconds re-claim next time.
      @last_web_second = @web_watermark if @web_watermark
    rescue => e
      buffer.repopulate_web(data[:web]) if data && data[:web].any?
      logger.error "[HireFire] Dispatch error: #{e.message}"
    end

    # A non-positive or unparseable value keeps the prior frequency, so a bad
    # response can't collapse the interval and storm ingest. Clamp the rest.
    def apply_dispatch_frequency(response)
      return unless response.respond_to?(:key?) && response.key?("HireFire-Dispatch-Frequency")

      value = response["HireFire-Dispatch-Frequency"].to_i
      return unless value.positive?

      @dispatch_frequency = value.clamp(DEFAULT_DISPATCH_FREQUENCY, MAX_DISPATCH_FREQUENCY)
    end

    # Drop rather than repopulate (a retry would re-send the same oversized
    # payload); advancing the watermark leaves a gap instead of backfilling false zeros.
    def drop_oversized_payload(body)
      @last_web_second = @web_watermark if @web_watermark
      logger.error "[HireFire] Dropped metrics payload: #{body.bytesize} bytes exceeds " \
        "the #{PAYLOAD_SIZE_LIMIT}-byte limit. Resuming from the current second."
    end

    def build_payload(data)
      entries = []

      if @web && @web_liveness
        samples = backfill_web_seconds(data[:web])
        @web_watermark = samples.keys.max
        entries << {"name" => @web.name, "samples" => samples.transform_keys(&:to_s)}
      elsif @web && data[:web].any?
        entries << {"name" => @web.name, "samples" => data[:web].transform_keys(&:to_s)}
      end

      entries.concat(data[:workers])

      data[:cpu].each do |name, samples|
        entries << {"name" => name, "samples" => samples.transform_keys(&:to_s)}
      end

      entries
    end

    def backfill_web_seconds(samples)
      now = Time.now.to_i
      from = @last_web_second ? @last_web_second + 1 : now
      from = now - WEB_BACKFILL_LIMIT if from < now - WEB_BACKFILL_LIMIT
      from = now if from > now

      samples = samples.dup # keep synthesized claims out of the retry buffer
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
