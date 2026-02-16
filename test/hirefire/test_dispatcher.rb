# frozen_string_literal: true

require "test_helper"

class HireFire::DispatcherTest < Minitest::Test
  def log
    @log ||= StringIO.new
  end

  def setup
    ENV["HIREFIRE_TOKEN"] = "test-token-value"
    ENV["HIREFIRE_DISPATCH_URL"] = nil
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

    Time.stub :now, Time.at(1000) do
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

  def test_web_buffer_repopulated_on_dispatch_failure
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .to_return(status: 500)

    dispatcher = configure_web_only

    Time.stub :now, Time.at(1000) do
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

    Time.stub :now, Time.at(1000) do
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
