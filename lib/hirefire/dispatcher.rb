# frozen_string_literal: true

module HireFire
  class Dispatcher
    # How far back (seconds) a dispatch may claim unreported web seconds.
    # Matches the server's ingest staleness acceptance and doubles as an
    # honesty cap: a process suspended longer than this must not assert
    # liveness for that time.
    WEB_BACKFILL_LIMIT = 60

    # Mirrors the server's request body cap; larger payloads are rejected with 413.
    PAYLOAD_SIZE_LIMIT = 65_536

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
    end

    # Fork-aware: a forked child inherits @running == true, but threads do not
    # survive fork, so "running" only counts in the process that started the
    # thread. In a child the pid check fails and start (called per request by
    # the middleware) creates a fresh thread for this process.
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
        # Only join a thread this process created; an inherited Thread object
        # in a forked child references a thread that no longer exists.
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

    # Each stage is isolated: a failure in one (a lease renewal timing out, a
    # job sampler raising) must not starve the stages after it — most
    # importantly dispatch, which drains the buffer.
    def tick
      guard { @lease.request_if_due }
      guard { @lease.sample_if_due { @workers.sample } }
      @cpu.each { |collector| guard { collector.sample } }
      dispatch
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
      @client.submit_samples(body)
      # Advance only after a successful submit so the next success re-claims
      # the seconds whose delivery failed; duplicate empty claims are harmless
      # server-side.
      @last_web_second = @web_watermark if @web_watermark
    rescue => e
      buffer.repopulate_web(data[:web]) if data && data[:web].any?
      logger.error "[HireFire] Dispatch error: #{e.message}"
    end

    # Repopulating would retry the same oversized payload every tick, so it is
    # dropped outright. Advancing the watermark leaves the dropped seconds
    # unclaimed (missing data) rather than backfilled as empty (zero traffic).
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
        # Identity says this is not the http-serving process: real samples are
        # still delivered, but no liveness is synthesized — this process must
        # not claim the web name's seconds.
        entries << {"name" => @web.name, "samples" => data[:web].transform_keys(&:to_s)}
      end

      entries.concat(data[:workers])

      data[:cpu].each do |name, samples|
        entries << {"name" => name, "samples" => samples.transform_keys(&:to_s)}
      end

      entries
    end

    # Claims every second since the last successfully dispatched one: seconds
    # with buffered samples keep them, seconds without get an explicit empty
    # claim, which the server reads as 0 traffic — so a delivery blip never
    # leaves a gap that an additive metric would misread as missing data. With
    # no watermark (first dispatch after boot) only the current second is
    # claimed: a fresh process must not assert liveness for time before it
    # existed.
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
