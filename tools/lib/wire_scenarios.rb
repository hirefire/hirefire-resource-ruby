# frozen_string_literal: true

require "json"
require "logger"
require "timecop"
require_relative "fake_server"

module Tools
  module WireScenarios
    extend self

    EPOCH = 1_767_225_600
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    IDENTITY_ENV = %w[DYNO HIREFIRE_SERVICE_NAME RENDER_SERVICE_NAME RENDER_SERVICE_TYPE RENDER RENDER_CPU_COUNT HIREFIRE_VERBOSE].freeze
    GEMFILES = {
      "ingest_rqt" => "default",
      "ingest_rqt_idle" => "default",
      "ingest_cpu" => "default",
      "lease_local_sampler" => "default",
      "lease_plan_trace" => "sidekiq_8"
    }.freeze
    GRANT_HEADERS = {
      "HireFire-Lease-Granted" => "true",
      "HireFire-Lease-TTL" => "5",
      "HireFire-Sample-Frequency" => "15"
    }.freeze

    def run(name, path)
      requests = send("scenario_#{name}")
      File.write(path, JSON.pretty_generate("scenario" => name, "epoch" => EPOCH, "requests" => requests) + "\n")
    end

    private

    def scenario_ingest_rqt
      capture(
        env: {"DYNO" => "web.1"},
        prepare: -> { [25, 75, 200].each { |value| HireFire.configuration.buffer.sample("web", "rqt", value) } },
        pick: {ingest: ->(body) { body.include?("rqt") }}
      )
    end

    def scenario_ingest_rqt_idle
      capture(env: {"DYNO" => "web.1"}, pick: {ingest: ->(body) { body.include?("rqt") }})
    end

    def scenario_ingest_cpu
      capture(
        env: {"HIREFIRE_SERVICE_NAME" => "worker"},
        pick: {ingest: ->(body) { body.include?("cpu") }},
        normalize: ->(payload) { payload.each { |entry| entry["metrics"]["cpu"]&.transform_values! { |value| "<#{value.class}>" } } }
      )
    end

    def scenario_lease_local_sampler
      grant = {status: 200, headers: GRANT_HEADERS, body: JSON.generate("job_queues" => [{"name" => "worker", "strategy" => "jqs"}])}
      capture(
        env: {},
        lease: grant,
        configure: ->(config) { config.dyno(:worker) { 42 } },
        pick: {lease: true, ingest: ->(body) { body.include?("jqs") }}
      )
    end

    def scenario_lease_plan_trace
      require "sidekiq"
      require "sidekiq/api"
      Sidekiq.configure_client { |config| config.redis = {url: ENV.fetch("TOOLS_REDIS_URL")} }
      Sidekiq.redis { |connection| connection.call("FLUSHDB") }
      3.times { Sidekiq::Client.push("class" => "GoldenJob", "args" => [], "queue" => "default") }

      plan = {
        "trace" => true,
        "job_queues" => [
          {"name" => "worker", "strategy" => "jqs", "adapter" => "sidekiq", "queues" => ["default"], "options" => {"skip_working" => true}},
          {"name" => "latency", "strategy" => "jql", "adapter" => "sidekiq", "queues" => ["empty"]}
        ]
      }
      capture(
        env: {},
        lease: {status: 200, headers: GRANT_HEADERS.merge("HireFire-Sample-Frequency" => "1"), body: JSON.generate(plan)},
        pick: {lease: true, ingest: ->(body) { whole_wave?(body) }},
        normalize: lambda do |payload|
          payload.each do |entry|
            trace = entry["sample_trace"] or next
            trace["wave_ms"] = "<#{trace["wave_ms"].class}>"
            trace["ops"].each { |op| op["ms"] = "<#{op["ms"].class}>" }
          end
        end
      )
    end

    def whole_wave?(body)
      payload = JSON.parse(body)
      payload.map { |entry| entry["name"] } == %w[worker latency] && payload.first.key?("sample_trace")
    end

    def capture(env:, pick:, lease: nil, prepare: nil, configure: nil, normalize: nil)
      server = FakeServer.new { |request| (request.path == "/metrics/lease" && lease) ? lease : {status: 200} }
      IDENTITY_ENV.each { |key| ENV.delete(key) }
      env.merge("HIREFIRE_TOKEN" => "golden-token", "HIREFIRE_DATA_URL" => server.url).each { |key, value| ENV[key] = value }
      require "hirefire-resource"

      chosen = nil
      Timecop.freeze(Time.at(EPOCH)) do
        prepare&.call
        HireFire.configure do |config|
          config.logger = Logger.new(File::NULL)
          configure&.call(config)
        end
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
        loop do
          chosen = choose(server.requests, pick)
          break if chosen || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep(0.02)
        end
        HireFire.configuration.stop_dispatcher(flush: false)
      end
      server.stop
      abort "scenario did not produce the expected requests (saw #{server.requests.map(&:path).tally})" unless chosen

      chosen.map { |request| record(request, normalize) }
    end

    def choose(requests, pick)
      found = []
      if pick[:lease]
        lease = requests.find { |request| request.path == "/metrics/lease" } or return nil
        found << lease
      end
      if pick[:ingest]
        ingest = requests.find { |request| request.path == "/metrics/ingest" && pick[:ingest].call(request.body) } or return nil
        found << ingest
      end
      found
    end

    def record(request, normalize)
      body = request.body
      normalized = false
      if normalize && request.path == "/metrics/ingest"
        payload = JSON.parse(body)
        normalize.call(payload)
        body = JSON.generate(payload)
        normalized = true
      end
      {
        "verb" => request.verb,
        "path" => request.path,
        "headers" => request.headers.map { |name, value| [name, header_value(name, value, normalized)] },
        "body" => body,
        "body_normalized" => normalized
      }
    end

    def header_value(name, value, normalized)
      return "<host>" if name.casecmp?("Host")
      return "<length>" if normalized && name.casecmp?("Content-Length")
      return "<uuid>" if name.casecmp?("HireFire-Process-ID") && value.match?(UUID)

      value
    end
  end
end
