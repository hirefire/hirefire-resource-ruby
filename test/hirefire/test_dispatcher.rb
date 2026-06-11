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
    HireFire.configuration.dyno(:web)
    HireFire.configuration.dyno(:worker) { 42 }
    HireFire.configuration.dyno(:mailer) { 18 }
    HireFire.configuration.dispatcher
  end

  def configure_web_only
    HireFire.configuration.dyno(:web)
    HireFire.configuration.dispatcher
  end

  def configure_workers_only
    HireFire.configuration.dyno(:worker) { 42 }
    HireFire.configuration.dyno(:mailer) { 18 }
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
end
