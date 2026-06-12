# frozen_string_literal: true

require "test_helper"

class HireFire::DispatcherTest < Minitest::Test
  def log
    @log ||= StringIO.new
  end

  def setup
    super
    ENV["HIREFIRE_TOKEN"] = "test-token-value"
    ENV["HIREFIRE_DATA_URL"] = nil
    WebMock.reset_executed_requests!
    HireFire.configuration.logger = Logger.new(log)
  end

  def stub_lease(granted: false)
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => granted.to_s,
        "HireFire-Sample-Frequency" => "15"
      })
  end

  def capture_ingest_bodies
    bodies = []
    stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .to_return do |request|
        bodies << JSON.parse(request.body)
        {status: 200}
      end
    bodies
  end

  def configure_web_and_workers
    HireFire.configuration.dyno(:web, :rqt)
    HireFire.configuration.dyno(:worker, :jql) { 42 }
    HireFire.configuration.dyno(:mailer, :jql) { 18 }
    HireFire.configuration.dispatcher
  end

  def configure_web_only
    HireFire.configuration.dyno(:web, :rqt)
    HireFire.configuration.dispatcher
  end

  def configure_workers_only
    HireFire.configuration.dyno(:worker, :jql) { 42 }
    HireFire.configuration.dyno(:mailer, :jql) { 18 }
    HireFire.configuration.dispatcher
  end

  def configure_cpu_only(name = "clock")
    ENV["HIREFIRE_SERVICE_NAME"] = name
    HireFire.configuration.dyno(name.to_sym, :cpu)
    HireFire.configuration.dispatcher
  end

  # -- Lifecycle --

  def test_starts_and_stops
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    dispatcher = configure_web_and_workers

    refute dispatcher.running?
    assert dispatcher.start
    assert dispatcher.running?
    refute dispatcher.start # idempotent
    assert dispatcher.stop
    refute dispatcher.running?
    refute dispatcher.stop # idempotent
  end

  # -- Web dispatch --

  def test_dispatches_web_metrics
    stub_lease
    request = stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .with { |req|
        body = JSON.parse(req.body)
        body.size == 1 &&
          body[0]["name"] == "web" &&
          body[0]["samples"].values.first == [12, 8]
      }
      .to_return(status: 200)

    dispatcher = configure_web_only

    Timecop.freeze Time.at(1000) do
      HireFire.configuration.buffer.sample_web(12)
      HireFire.configuration.buffer.sample_web(8)
      dispatcher.send(:tick)
    end

    assert_requested request
  end

  def test_dispatches_heartbeat_when_web_configured_but_no_traffic
    stub_lease
    request = stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .with { |req|
        body = JSON.parse(req.body)
        body.size == 1 &&
          body[0]["name"] == "web" &&
          body[0]["samples"].values.first == []
      }
      .to_return(status: 200)

    dispatcher = configure_web_only
    dispatcher.send(:tick)

    assert_requested request
  end

  def test_no_dispatch_when_nothing_configured
    stub_lease
    dispatcher = HireFire.configuration.dispatcher
    dispatcher.send(:tick)

    assert_not_requested(:post, "https://data.hirefire.io/metrics/ingest")
  end

  # -- Web backfill (per-second liveness claims) --

  def test_first_dispatch_claims_only_the_current_second
    stub_lease
    bodies = capture_ingest_bodies

    dispatcher = configure_web_only
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }

    # No watermark yet: a fresh process must not assert liveness for time
    # before it existed (deploy/restart gaps stay genuinely visible).
    assert_equal({"1000" => []}, bodies[0][0]["samples"])
  end

  def test_backfills_seconds_skipped_between_dispatches
    stub_lease
    bodies = capture_ingest_bodies

    dispatcher = configure_web_only
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }
    Timecop.freeze(Time.at(1003)) { dispatcher.send(:tick) }

    # The skipped seconds (1001, 1002) are claimed as empty — alive, no traffic —
    # so a stalled dispatch loop never leaves unreported gaps.
    assert_equal({"1001" => [], "1002" => [], "1003" => []}, bodies[1][0]["samples"])
  end

  def test_backfill_preserves_buffered_samples
    stub_lease
    bodies = capture_ingest_bodies

    dispatcher = configure_web_only
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }
    Timecop.freeze(Time.at(1003)) do
      HireFire.configuration.buffer.sample_web(5)
      dispatcher.send(:tick)
    end

    assert_equal({"1001" => [], "1002" => [], "1003" => [5]}, bodies[1][0]["samples"])
  end

  def test_seconds_from_a_failed_dispatch_are_reclaimed_by_the_next_success
    stub_lease
    bodies = []
    calls = 0
    stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .to_return do |request|
        calls += 1
        bodies << JSON.parse(request.body)
        {status: (calls == 2) ? 500 : 200}
      end

    dispatcher = configure_web_only
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) } # 200 — watermark 1000
    Timecop.freeze(Time.at(1003)) { dispatcher.send(:tick) } # 500 — watermark must not advance
    Timecop.freeze(Time.at(1005)) { dispatcher.send(:tick) } # 200 — re-claims the failed seconds

    assert_equal %w[1001 1002 1003 1004 1005], bodies[2][0]["samples"].keys.sort
  end

  def test_backfill_is_capped_at_the_limit
    stub_lease
    bodies = capture_ingest_bodies

    dispatcher = configure_web_only
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }
    Timecop.freeze(Time.at(1000 + 100)) { dispatcher.send(:tick) }

    # A 100s gap claims only the last WEB_BACKFILL_LIMIT seconds: older claims
    # would be rejected by the server anyway, and a process suspended that long
    # must not assert liveness for the suspension.
    keys = bodies[1][0]["samples"].keys.map(&:to_i)
    assert_equal 1100 - HireFire::Dispatcher::WEB_BACKFILL_LIMIT, keys.min
    assert_equal 1100, keys.max
    assert_equal HireFire::Dispatcher::WEB_BACKFILL_LIMIT + 1, keys.size
  end

  def test_lease_unauthorized_does_not_log_error
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 401)

    dispatcher = configure_workers_only
    dispatcher.send(:tick)

    assert_not_requested(:post, "https://data.hirefire.io/metrics/ingest")
    refute_includes log.string, "401"
  end

  def test_web_buffer_discarded_on_unauthorized
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .to_return(status: 401)

    dispatcher = configure_web_only

    Timecop.freeze Time.at(1000) do
      HireFire.configuration.buffer.sample_web(7)
      dispatcher.send(:tick)
    end

    data = HireFire.configuration.buffer.flush
    assert_empty data[:web]
    refute_includes log.string, "Dispatch error"
  end

  def test_web_buffer_repopulated_on_dispatch_failure
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .to_return(status: 500)

    dispatcher = configure_web_only

    Timecop.freeze Time.at(1000) do
      HireFire.configuration.buffer.sample_web(7)
      dispatcher.send(:tick)
    end

    data = HireFire.configuration.buffer.flush
    assert_equal [7], data[:web][1000]
  end

  # -- Oversized payload drop --

  def test_oversized_payload_is_dropped_without_a_request
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    dispatcher = configure_web_only

    Timecop.freeze Time.at(1000) do
      15_000.times { HireFire.configuration.buffer.sample_web(12345) }
      dispatcher.send(:tick)
    end

    # Dropped wholesale: nothing is sent, and nothing is repopulated for retry —
    # repopulating would re-attempt the same oversized payload every tick.
    assert_not_requested(:post, "https://data.hirefire.io/metrics/ingest")
    assert_empty HireFire.configuration.buffer.flush[:web]
    assert_includes log.string, "Dropped metrics payload"
  end

  def test_oversized_drop_advances_the_watermark_past_the_hole
    stub_lease
    bodies = capture_ingest_bodies

    dispatcher = configure_web_only
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) } # watermark 1000
    Timecop.freeze Time.at(1010) do
      15_000.times { HireFire.configuration.buffer.sample_web(12345) }
      dispatcher.send(:tick) # oversized — dropped, watermark advances to 1010
    end
    Timecop.freeze(Time.at(1012)) { dispatcher.send(:tick) }

    # The next dispatch must not backfill the dropped seconds as empty claims:
    # that would report heavy traffic as zero traffic. Advancing the watermark
    # leaves them unclaimed, which the server reads as missing data instead.
    assert_equal 2, bodies.size
    assert_equal %w[1011 1012], bodies[1][0]["samples"].keys.sort
  end

  # -- Combined dispatch --

  def test_combined_web_and_worker_dispatch
    stub_lease(granted: true)

    ingest = stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .with { |req|
        body = JSON.parse(req.body)
        has_web = body.any? { |e| e.key?("samples") && e["name"] == "web" }
        has_worker = body.any? { |e| e["name"] == "worker" && e["sample"] == 42 }
        has_web && has_worker
      }
      .to_return(status: 200)

    Timecop.freeze Time.at(1000) do
      dispatcher = configure_web_and_workers
      HireFire.configuration.buffer.sample_web(5)
      dispatcher.send(:tick)
    end

    assert_requested ingest
  end

  # -- Worker-only dispatch via lease --

  def test_lease_granted_dispatches_workers
    stub_lease(granted: true)

    ingest = stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .with { |req|
        body = JSON.parse(req.body)
        body.any? { |e| e["name"] == "worker" && e["sample"] == 42 }
      }
      .to_return(status: 200)

    dispatcher = configure_workers_only
    dispatcher.send(:tick)

    assert_requested ingest
  end

  def test_lease_denied_skips_worker_collection
    stub_lease

    dispatcher = configure_workers_only
    dispatcher.send(:tick)

    assert_not_requested(:post, "https://data.hirefire.io/metrics/ingest")
  end

  # -- CPU dispatch --

  def test_dispatches_cpu_samples_in_the_samples_format
    HireFire::CPU::Usage.stubs(:available_cpus).returns(1.0)
    HireFire::CPU::Usage.stubs(:total_seconds).returns(0.0, 0.5)
    bodies = capture_ingest_bodies

    dispatcher = configure_cpu_only("clock")
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) } # seeds baseline only
    Timecop.freeze(Time.at(1001)) { dispatcher.send(:tick) } # 0.5 core over 1s => 50%

    assert_equal 1, bodies.size
    entry = bodies[0][0]
    assert_equal "clock", entry["name"]
    assert_equal({"1001" => [50.0]}, entry["samples"])
  end

  def test_cpu_first_tick_seeds_baseline_without_dispatching
    HireFire::CPU::Usage.stubs(:available_cpus).returns(1.0)
    HireFire::CPU::Usage.stubs(:total_seconds).returns(0.0)
    bodies = capture_ingest_bodies

    dispatcher = configure_cpu_only("clock")
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }

    # No previous reading to diff against, and CPU sends no heartbeat, so there
    # is nothing to dispatch yet.
    assert_empty bodies
  end

  def test_cpu_samples_are_not_repopulated_on_dispatch_failure
    HireFire::CPU::Usage.stubs(:available_cpus).returns(1.0)
    HireFire::CPU::Usage.stubs(:total_seconds).returns(0.0, 0.5)
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 500)

    dispatcher = configure_cpu_only("clock")
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }
    Timecop.freeze(Time.at(1001)) { dispatcher.send(:tick) } # 500 — sample is dropped

    # Unlike web, CPU is not re-buffered on failure: a missed second thins the
    # fleet mean rather than biasing it.
    data = HireFire.configuration.buffer.flush
    assert_empty data[:cpu]
  end

  # -- http liveness soft gate --

  def test_non_web_process_does_not_heartbeat_the_web_name
    stub_lease
    ENV["DYNO"] = "worker.1"
    HireFire.configuration.dyno(:web, :rqt)
    dispatcher = HireFire.configuration.dispatcher

    dispatcher.send(:tick)

    # An idle worker process must not claim "web alive, zero traffic" seconds —
    # that would satisfy an additive metric's coverage check during a web outage.
    assert_not_requested(:post, "https://data.hirefire.io/metrics/ingest")
  end

  def test_non_web_process_still_delivers_real_web_samples
    stub_lease
    ENV["DYNO"] = "worker.1"
    HireFire.configuration.dyno(:web, :rqt)
    dispatcher = HireFire.configuration.dispatcher
    bodies = capture_ingest_bodies

    Timecop.freeze(Time.at(1000)) do
      HireFire.configuration.buffer.sample_web(12)
      dispatcher.send(:tick)
    end

    # Real data is never dropped — only synthesized liveness is suppressed.
    assert_equal({"1000" => [12]}, bodies[0][0]["samples"])
  end

  def test_matching_identity_keeps_heartbeat_and_backfill
    stub_lease
    ENV["DYNO"] = "web.1"
    HireFire.configuration.dyno(:web, :rqt)
    dispatcher = HireFire.configuration.dispatcher
    bodies = capture_ingest_bodies

    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }
    Timecop.freeze(Time.at(1002)) { dispatcher.send(:tick) }

    assert_equal({"1000" => []}, bodies[0][0]["samples"])
    assert_equal({"1001" => [], "1002" => []}, bodies[1][0]["samples"])
  end

  def test_unresolved_identity_keeps_heartbeat
    stub_lease
    HireFire.configuration.dyno(:web, :rqt)
    dispatcher = HireFire.configuration.dispatcher
    bodies = capture_ingest_bodies

    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }

    # Soft gate: without a resolver the http collector keeps current behavior.
    assert_equal({"1000" => []}, bodies[0][0]["samples"])
  end

  def test_mismatched_cpu_collector_stays_dormant_through_the_tick
    stub_lease
    bodies = capture_ingest_bodies

    ENV["HIREFIRE_SERVICE_NAME"] = "web"
    HireFire.configuration.dyno(:web, :rqt)
    HireFire.configuration.dyno(:worker, :cpu) # dormant here: identity is "web"
    dispatcher = HireFire.configuration.dispatcher

    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }

    # Identity is "web", so the "worker" CPU collector never samples; only the
    # web heartbeat is emitted.
    assert_equal ["web"], bodies[0].map { |e| e["name"] }
  end

  # -- Fork awareness --

  def test_forked_child_restarts_the_dispatcher
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    dispatcher = configure_web_only
    assert dispatcher.start

    # Simulate a fork: the child inherits @running == true from the parent
    # (e.g. Puma preload_app!), but threads do not survive fork.
    child_pid = Process.pid + 1
    Process.stubs(:pid).returns(child_pid)

    refute dispatcher.running?
    assert dispatcher.start # the middleware's per-request start recovers
    assert dispatcher.running?

    dispatcher.stop
  end

  # -- Tick stage isolation --

  def test_tick_dispatches_when_the_lease_request_fails
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_raise(Errno::ECONNREFUSED)
    bodies = capture_ingest_bodies

    Timecop.freeze Time.at(1000) do
      dispatcher = configure_web_and_workers
      HireFire.configuration.buffer.sample_web(12)
      dispatcher.send(:tick)
    end

    # The failed lease renewal is logged, but must not starve dispatch.
    assert_equal 1, bodies.size
    assert_includes log.string, "Network error"
  end

  def test_tick_dispatches_when_a_sampler_raises
    stub_lease(granted: true)
    bodies = capture_ingest_bodies

    Timecop.freeze Time.at(1000) do
      HireFire.configuration.dyno(:web, :rqt)
      HireFire.configuration.dyno(:worker, :jql) { raise "Redis down" }
      HireFire.configuration.dispatcher.send(:tick)
    end

    # The raising sampler is logged, but the web heartbeat still goes out.
    assert_equal 1, bodies.size
    assert_equal ["web"], bodies[0].map { |e| e["name"] }
    assert_includes log.string, "Redis down"
  end
end
