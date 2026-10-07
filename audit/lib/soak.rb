# frozen_string_literal: true

require "json"
require "logger"
require "stringio"
require_relative "fake_server"

module Audit
  class Soak
    GRANT_HEADERS = {"HireFire-Lease-Granted" => "true", "HireFire-Lease-TTL" => "5", "HireFire-Sample-Frequency" => "2"}.freeze
    PLAN = JSON.generate(
      "job_queues" => [
        {"name" => "worker", "strategy" => "jqs", "adapter" => "sidekiq", "queues" => %w[default mailers], "options" => {"skip_working" => true}},
        {"name" => "worker-latency", "strategy" => "jql", "adapter" => "sidekiq", "queues" => ["default"]},
        {"name" => "local", "strategy" => "jqs"}
      ]
    ).freeze
    GRANT = {status: 200, headers: GRANT_HEADERS, body: PLAN}.freeze
    HEALTHY = ->(request) { (request.path == "/metrics/lease") ? GRANT : {status: 200} }
    PHASES = [
      ["healthy", HEALTHY],
      ["status_500", ->(_request) { {status: 500} }],
      ["healthy", HEALTHY],
      ["stall", ->(_request) { {then: :stall} }],
      ["healthy", HEALTHY],
      ["reset", ->(_request) { {then: :reset} }],
      ["healthy", HEALTHY],
      ["status_401", ->(_request) { {status: 401} }],
      ["healthy", HEALTHY],
      ["garbage", ->(_request) { {raw: "\x00\xFFnot http\r\n\r\n".b, after: :close} }],
      ["healthy", HEALTHY],
      ["lease_denied", ->(request) { (request.path == "/metrics/lease") ? {status: 200, headers: {"HireFire-Lease-Granted" => "false", "HireFire-Lease-TTL" => "5"}} : {status: 200} }]
    ].freeze
    PHASE_SECONDS = 20
    FORK_EVERY = 15
    SAMPLE_EVERY = 10

    def initialize(seconds:, csv:)
      @seconds = seconds
      @csv = csv
      @log = StringIO.new
      @escaped = []
      @running = true
      @middleware_max = 0.0
      @middleware_calls = 0
      @lock = Mutex.new
      @forks = []
      @restart_delays = []
      @phase = "healthy"
    end

    def run
      server = FakeServer.new(&HEALTHY)
      seed_sidekiq
      ENV["HIREFIRE_TOKEN"] = "soak-token"
      ENV["HIREFIRE_DATA_URL"] = server.url
      ENV["DYNO"] = "web.1"
      require "hirefire-resource"

      HireFire.configure do |config|
        config.logger = Logger.new(@log)
        config.dyno(:local) { 11 }
      end
      hosts = Array.new(4) { Thread.new { host_loop } }
      sleep(2)

      rows = []
      started = now
      next_sample = started
      next_fork = started + FORK_EVERY
      next_phase = started
      phase_index = -1
      pids = []

      while now - started < @seconds
        if now >= next_phase
          phase_index += 1
          @phase, handler = PHASES[phase_index % PHASES.size]
          server.handler = handler
          next_phase += PHASE_SECONDS
        end
        if now >= next_fork
          pids << fork_child(pids.size)
          next_fork += FORK_EVERY
        end
        pids.reject! { |pid| Process.wait(pid, Process::WNOHANG) }
        if now >= next_sample
          rows << sample(server, started, pids.size)
          next_sample += SAMPLE_EVERY
        end
        sleep(0.1)
      end

      server.handler = HEALTHY
      sleep(3)
      rows << sample(server, started, pids.size)
      @running = false
      hosts.each { |host| host.join(2) }
      stop_started = now
      guard("stop") { HireFire.configuration.stop_dispatcher }
      stop_seconds = now - stop_started
      pids.each { |pid| Process.wait(pid) }
      final = sample(server, started, 0)
      requests = server.requests
      server.stop

      write_csv(rows)
      summary(rows, final, requests, stop_seconds)
    end

    private

    def seed_sidekiq
      require "sidekiq"
      require "sidekiq/api"
      Sidekiq.configure_client do |config|
        config.redis = {url: ENV.fetch("AUDIT_REDIS_URL")}
        config.logger = Logger.new(File::NULL)
      end
      Sidekiq.redis { |connection| connection.call("FLUSHDB") }
      200.times { Sidekiq::Client.push("class" => "SoakJob", "args" => [], "queue" => "default") }
      50.times { Sidekiq::Client.push("class" => "SoakJob", "args" => [], "queue" => "mailers") }
      600.times { |index| Sidekiq::Client.push("class" => "SoakJob", "args" => [], "queue" => %w[default mailers other][index % 3], "at" => Time.now.to_f + ((index < 300) ? -60 : 3600)) }
    end

    def host_loop
      app = HireFire::Middleware.new(->(_env) { [200, {}, []] })
      while @running
        env = {"HTTP_X_REQUEST_START" => "t=#{Time.now.to_f - 0.015}"}
        started = now
        guard("middleware") { app.call(env) }
        elapsed = now - started
        @lock.synchronize do
          @middleware_calls += 1
          @middleware_max = elapsed if elapsed > @middleware_max
        end
        sleep(0.02)
      end
    end

    def fork_child(index)
      started = now
      pid = fork do
        ObjectSpace.each_object(TCPServer) { |socket| socket.close unless socket.closed? }
        sleep(2.5)
        index.even? ? exit(0) : exit!(0)
      end
      fork_seconds = now - started
      restart_started = now
      sleep(0.01) until HireFire.configuration.dispatcher.running? || now - restart_started > 10
      @forks << {phase: @phase, fork_seconds: fork_seconds.round(3), restart_seconds: (now - restart_started).round(3)}
      pid
    end

    def guard(where)
      yield
    rescue Exception => error # standard:disable Lint/RescueException
      @lock.synchronize { @escaped << "#{where}: #{error.class}: #{error.message}" }
      nil
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def sample(server, started, children)
      {
        seconds: (now - started).round,
        phase: @phase,
        rss_kb: `ps -o rss= -p #{Process.pid}`.to_i,
        threads: Thread.list.size - server.live_threads,
        fds: Dir["/dev/fd/*"].size,
        server_open_sockets: server.open_sockets,
        connections_accepted: server.accepted,
        requests: server.requests.size,
        heap_live_slots: GC.stat(:heap_live_slots),
        log_lines: @log.string.count("\n"),
        children: children,
        running: HireFire.configuration.dispatcher.running?
      }
    end

    def write_csv(rows)
      keys = rows.first.keys
      File.write(@csv, ([keys.join(",")] + rows.map { |row| keys.map { |key| row[key] }.join(",") }).join("\n") + "\n")
    end

    def summary(rows, final, requests, stop_seconds)
      steady = rows.drop(rows.size / 3)
      minutes = (steady.last[:seconds] - steady.first[:seconds]) / 60.0
      lines = @log.string.lines
      messages = lines.map { |line| line.sub(/\A.*?\[HireFire\]/, "[HireFire]").gsub(/\d+(\.\d+)?/, "N").strip[0, 100] }
      range = ->(key) {
        values = rows.map { |row| row[key] }
        {first: values.first, last: values.last, min: values.min, max: values.max}
      }
      {
        seconds: rows.last[:seconds],
        samples: rows.size,
        rss_kb: range.call(:rss_kb),
        rss_growth_kb_per_minute_last_two_thirds: ((steady.last[:rss_kb] - steady.first[:rss_kb]) / minutes).round(1),
        heap_live_slots: range.call(:heap_live_slots),
        threads: range.call(:threads),
        fds: range.call(:fds),
        server_open_sockets: range.call(:server_open_sockets),
        connections_accepted: rows.last[:connections_accepted],
        requests: requests.size,
        requests_by_path: requests.map(&:path).tally,
        middleware_calls: @middleware_calls,
        middleware_max_ms: (@middleware_max * 1000).round(2),
        forks: @forks.size,
        fork_seconds_max: @forks.map { |entry| entry[:fork_seconds] }.max,
        slowest_forks: @forks.sort_by { |entry| -entry[:fork_seconds] }.first(5),
        restart_seconds_max: @forks.map { |entry| entry[:restart_seconds] }.max,
        escaped: @escaped,
        log_lines: lines.size,
        log_levels: lines.map { |line| line[0] }.tally,
        top_messages: messages.tally.sort_by { |_, count| -count }.first(12).map { |message, count| "#{count}x #{message}" },
        stop_seconds: stop_seconds.round(2),
        after_stop: {threads: final[:threads], fds: final[:fds], server_open_sockets: final[:server_open_sockets]}
      }
    end
  end
end
