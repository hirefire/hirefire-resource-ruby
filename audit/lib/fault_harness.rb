# frozen_string_literal: true

require "json"
require "logger"
require "stringio"
require_relative "fake_server"

module Audit
  class FaultHarness
    GRANT_HEADERS = {"HireFire-Lease-Granted" => "true", "HireFire-Lease-TTL" => "5", "HireFire-Sample-Frequency" => "1"}.freeze
    PLAN = JSON.generate("job_queues" => [{"name" => "worker", "strategy" => "jqs"}]).freeze
    GRANT = {status: 200, headers: GRANT_HEADERS, body: PLAN}.freeze
    HEALTHY = ->(request) { (request.path == "/metrics/lease") ? GRANT : {status: 200} }
    LEASE_ONLY = ->(lease) { ->(request) { (request.path == "/metrics/lease") ? lease : {status: 200} } }
    INGEST_ONLY = ->(ingest) { ->(request) { (request.path == "/metrics/lease") ? GRANT : ingest } }
    HUGE_PLAN = JSON.generate("job_queues" => Array.new(4000) { |index| {"name" => "queue-#{index}", "strategy" => "jqs", "adapter" => "sidekiq", "queues" => ["q#{index}"]} }).freeze

    SERVER_FAULTS = {
      "healthy" => HEALTHY,
      "stall" => ->(_request) { {then: :stall} },
      "reset" => ->(_request) { {then: :reset} },
      "close" => ->(_request) { {then: :close} },
      "garbage" => ->(_request) { {raw: "\x00\xFFthis is not http\r\n\r\n".b, after: :close} },
      "drip" => ->(_request) { {status: 200, body: "x" * 40, drip: 1.0} },
      "slow_200" => ->(request) { HEALTHY.call(request).merge(delay: 3) },
      "status_302" => ->(_request) { {status: 302, headers: {"Location" => "/elsewhere"}} },
      "status_401" => ->(_request) { {status: 401} },
      "status_413" => INGEST_ONLY.call({status: 413}),
      "status_429" => ->(_request) { {status: 429, headers: {"Retry-After" => "30"}} },
      "status_500" => ->(_request) { {status: 500} },
      "status_503" => ->(_request) { {status: 503} },
      "lease_bad_json" => LEASE_ONLY.call({status: 200, headers: GRANT_HEADERS, body: "{not json"}),
      "lease_wrong_shape" => LEASE_ONLY.call({status: 200, headers: GRANT_HEADERS, body: JSON.generate("job_queues" => [1, "two", nil, {"name" => 5}, {"name" => "worker", "strategy" => ["jqs"]}])}),
      "lease_huge_body" => LEASE_ONLY.call({status: 200, headers: GRANT_HEADERS, body: HUGE_PLAN}),
      "lease_bad_headers" => LEASE_ONLY.call({status: 200, headers: {"HireFire-Lease-Granted" => "true", "HireFire-Lease-TTL" => "abc", "HireFire-Sample-Frequency" => "-5"}, body: PLAN}),
      "lease_binary_body" => LEASE_ONLY.call({status: 200, headers: GRANT_HEADERS, body: "\xFF\xFE\x00\x01{".b})
    }.freeze
    CONNECTION_FAULTS = %w[refused unresolvable tls_to_plain].freeze
    SCENARIOS = (SERVER_FAULTS.keys + CONNECTION_FAULTS).freeze

    def initialize(scenario, fault_seconds:, heal_seconds:)
      @scenario = scenario
      @fault_seconds = fault_seconds
      @heal_seconds = heal_seconds
      @log = StringIO.new
      @escaped = []
      @durations = []
      @host_running = true
    end

    def run
      server = FakeServer.new(&SERVER_FAULTS.fetch(@scenario, HEALTHY))
      ENV["HIREFIRE_TOKEN"] = "fault-token"
      ENV["HIREFIRE_DATA_URL"] = data_url(server)
      ENV["DYNO"] = "web.1"
      require "hirefire-resource"

      guard("configure") do
        HireFire.configure do |config|
          config.logger = Logger.new(@log)
          config.dyno(:worker) { 7 }
        end
      end
      host = Thread.new { host_loop }
      sleep(1)
      start = snapshot(server)

      sleep(@fault_seconds)
      fault = snapshot(server)
      fault_log = @log.string.dup
      fault_requests = server.requests
      running_after_fault = guard("running?") { HireFire.configuration.dispatcher.running? }

      healed_after = nil
      if SERVER_FAULTS.key?(@scenario)
        server.handler = HEALTHY
        healed_at = now
        deadline = healed_at + @heal_seconds
        loop do
          first = server.requests.find { |request| request.at > healed_at && request.path == "/metrics/ingest" }
          if first
            healed_after = (first.at - healed_at).round(2)
            break
          end
          break if now > deadline

          sleep(0.05)
        end
        sleep(1)
        server.handler = SERVER_FAULTS.fetch(@scenario)
        sleep(3)
      end

      stop_started = now
      guard("stop") { HireFire.configuration.stop_dispatcher }
      stop_seconds = (now - stop_started).round(2)

      @host_running = false
      host.join(2)
      finish = snapshot(server)
      server.stop
      result(start, fault, finish, fault_log, fault_requests, running_after_fault, healed_after, stop_seconds)
    end

    private

    def data_url(server)
      case @scenario
      when "refused"
        closed = TCPServer.new("127.0.0.1", 0)
        port = closed.addr[1]
        closed.close
        "http://127.0.0.1:#{port}"
      when "unresolvable" then "http://nonexistent-host.invalid"
      when "tls_to_plain" then "https://127.0.0.1:#{server.port}"
      else server.url
      end
    end

    def host_loop
      app = HireFire::Middleware.new(->(_env) { [200, {}, []] })
      while @host_running
        env = {"HTTP_X_REQUEST_START" => "t=#{Time.now.to_f - 0.02}"}
        started = now
        guard("middleware") { app.call(env) }
        @durations << (now - started)
        sleep(0.005)
      end
    end

    def guard(where)
      yield
    rescue Exception => error # standard:disable Lint/RescueException
      @escaped << "#{where}: #{error.class}: #{error.message}"
      nil
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def snapshot(server)
      {
        at: now,
        rss_kb: `ps -o rss= -p #{Process.pid}`.to_i,
        threads: Thread.list.size - server.live_threads,
        accepted: server.accepted,
        open_sockets: server.open_sockets,
        requests: server.requests.size,
        log_lines: @log.string.count("\n")
      }
    end

    def result(start, fault, finish, fault_log, fault_requests, running_after_fault, healed_after, stop_seconds)
      lines = fault_log.lines
      seconds = fault[:at] - start[:at]
      durations = @durations.sort
      messages = lines.map { |line| line.sub(/\A.*?\[HireFire\]/, "[HireFire]").gsub(/\d+(\.\d+)?/, "N").strip[0, 110] }
      {
        scenario: @scenario,
        fault_seconds: seconds.round(1),
        escaped: @escaped,
        middleware_calls: durations.size,
        middleware_p99_ms: (durations[(durations.size * 0.99).floor] * 1000).round(3),
        middleware_max_ms: (durations.last * 1000).round(3),
        ingest_requests: fault_requests.count { |request| request.path == "/metrics/ingest" },
        lease_requests: fault_requests.count { |request| request.path == "/metrics/lease" },
        connections_accepted: fault[:accepted],
        log_lines: lines.size,
        log_lines_per_minute: (lines.size * 60 / seconds).round,
        log_levels: lines.map { |line| line[0] }.tally,
        top_messages: messages.tally.sort_by { |_, count| -count }.first(4).map { |message, count| "#{count}x #{message}" },
        dispatcher_running_after_fault: running_after_fault,
        threads_start: start[:threads],
        threads_after_fault: fault[:threads],
        threads_after_stop: finish[:threads],
        rss_start_kb: start[:rss_kb],
        rss_after_fault_kb: fault[:rss_kb],
        recovered_after_seconds: healed_after,
        stop_seconds_under_fault: stop_seconds
      }
    end
  end
end
