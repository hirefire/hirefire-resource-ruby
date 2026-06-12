# frozen_string_literal: true

module HireFire
  class Dispatcher
    # How far back (seconds) a dispatch may claim unreported web seconds. Matches
    # the server's ingest staleness acceptance — claims older than this would be
    # rejected anyway — and doubles as an honesty cap: a process that was
    # suspended longer than this must not assert liveness for that time.
    WEB_BACKFILL_LIMIT = 60

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

    # Fork-aware: a forked child inherits @running == true from a parent that
    # started the dispatcher (e.g. HireFire.configure under Puma's
    # preload_app!), but threads do not survive fork — so "running" only counts
    # in the process that started the thread. In a child the pid check fails,
    # start runs again (the middleware calls it per request), and a fresh
    # thread is created for this process.
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
    # importantly dispatch, which drains the buffer. Without isolation a
    # persistently failing early stage would abort every tick and let the web
    # buffer grow without bound.
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

      if @web && @web_liveness
        samples = backfill_web_seconds(data[:web])
        @web_watermark = samples.keys.max
        entries << {"name" => @web.name, "samples" => samples.transform_keys(&:to_s)}
      elsif @web && data[:web].any?
        # Identity says this is not the http-serving process: real samples are
        # still delivered (data must never be dropped), but no liveness is
        # synthesized — this process must not claim the web name's seconds.
        entries << {"name" => @web.name, "samples" => data[:web].transform_keys(&:to_s)}
      end

      entries.concat(data[:workers])

      # CPU is pushed raw in the samples format under each declared name, with
      # no heartbeat or backfill: a missed second thins the fleet mean rather
      # than biasing it, so synthesizing empty seconds would be wrong here.
      data[:cpu].each do |name, samples|
        entries << {"name" => name, "samples" => samples.transform_keys(&:to_s)}
      end

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
