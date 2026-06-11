# frozen_string_literal: true

module HireFire
  class Dispatcher
    # How far back (seconds) a dispatch may claim unreported web seconds. Matches
    # the server's ingest staleness acceptance — claims older than this would be
    # rejected anyway — and doubles as an honesty cap: a process that was
    # suspended longer than this must not assert liveness for that time.
    WEB_BACKFILL_LIMIT = 60

    def initialize(web: nil, workers: Workers.new)
      @web = web
      @workers = workers
      @client = Client.new
      @lease = Lease.new(enabled: workers.any?)
      @mutex = Mutex.new
      @running = false
      @last_web_second = nil
    end

    def start
      return false if @running

      @mutex.synchronize do
        return false if @running
        @running = true
      end

      @thread = Thread.new do
        while running?
          tick
          sleep 1
        end
      end

      logger.info "[HireFire] Starting dispatcher."

      true
    end

    def stop
      @mutex.synchronize do
        return false unless @running
        @running = false
      end

      @thread&.join(5)
      @thread = nil

      dispatch

      logger.info "[HireFire] Dispatcher stopped."

      true
    end

    def running?
      @mutex.synchronize { @running }
    end

    private

    def tick
      @lease.request_if_due
      @lease.sample_if_due { @workers.sample }
      dispatch
    rescue => e
      logger.error "[HireFire] #{e.message}"
    end

    def dispatch
      data = buffer.flush
      payload = build_payload(data)
      return if payload.empty?

      logger.info "[HireFire] Dispatching metrics: #{payload}" if ENV["HIREFIRE_VERBOSE"]
      @client.submit_samples(payload)
      # Advance only after a successful submit: a failed dispatch leaves the
      # watermark behind, so the next success re-claims (and the server
      # re-receives) the seconds whose delivery failed. Duplicate empty claims
      # are harmless server-side.
      @last_web_second = @web_watermark if @web_watermark
    rescue => e
      buffer.repopulate_web(data[:web]) if data && data[:web].any?
      logger.error "[HireFire] Dispatch error: #{e.message}"
    end

    def build_payload(data)
      entries = []

      if @web
        samples = backfill_web_seconds(data[:web])
        @web_watermark = samples.keys.max
        entries << {"name" => @web.name, "samples" => samples.transform_keys(&:to_s)}
      end

      entries.concat(data[:workers])

      entries
    end

    # Claims every second since the last successfully dispatched one: seconds
    # with buffered samples keep them, seconds without get an explicit empty
    # claim ("this process was alive and buffered nothing"). The server reads
    # an empty claim as 0 traffic for that second, so dispatch-loop jitter or
    # a delivery blip never leaves an unreported gap that an additive metric
    # (requests per minute) would misread as missing data. Subsumes the old
    # single-second heartbeat: with no watermark (first dispatch after boot)
    # only the current second is claimed — a fresh process must not assert
    # liveness for time before it existed.
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
