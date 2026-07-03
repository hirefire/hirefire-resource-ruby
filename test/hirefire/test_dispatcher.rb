# frozen_string_literal: true

require "test_helper"

class HireFire::DispatcherTest < Minitest::Test
  def log
    @log ||= StringIO.new
  end

  def setup
    super
    ENV["HIREFIRE_TOKEN"] = "test-token-value"
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

  def configure_cpu_only(name = "clock")
    ENV["HIREFIRE_SERVICE_NAME"] = name
    HireFire.configuration.dyno(name.to_sym, tracking: :cpu)
    HireFire.configuration.dispatcher
  end

  def test_starts_and_stops
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    dispatcher = configure_web_and_workers

    refute dispatcher.running?
    assert dispatcher.start
    assert dispatcher.running?
    refute dispatcher.start
    assert dispatcher.stop
    refute dispatcher.running?
    refute dispatcher.stop
  end

  def test_a_failed_thread_spawn_leaves_the_dispatcher_retryable
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
    dispatcher = configure_web_only

    Thread.stubs(:new).raises(ThreadError.new("cannot create thread"))
    refute dispatcher.start
    refute dispatcher.running?
    assert_includes log.string, "Could not start dispatcher"

    Thread.unstub(:new)
    assert dispatcher.start
    assert dispatcher.running?
    dispatcher.stop
  end

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

  def test_no_dispatch_when_nothing_configured
    stub_lease
    dispatcher = HireFire.configuration.dispatcher
    dispatcher.send(:tick)

    assert_not_requested(:post, "https://data.hirefire.io/metrics/ingest")
  end

  def test_first_dispatch_claims_only_the_current_second
    stub_lease
    bodies = capture_ingest_bodies

    dispatcher = configure_web_only
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }

    assert_equal({"1000" => []}, bodies[0][0]["samples"])
  end

  def test_backfills_seconds_skipped_between_dispatches
    stub_lease
    bodies = capture_ingest_bodies

    dispatcher = configure_web_only
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }
    Timecop.freeze(Time.at(1003)) { dispatcher.send(:tick) }

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
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }
    Timecop.freeze(Time.at(1003)) { dispatcher.send(:tick) }
    Timecop.freeze(Time.at(1005)) { dispatcher.send(:tick) }

    assert_equal %w[1001 1002 1003 1004 1005], bodies[2][0]["samples"].keys.sort
  end

  def test_backfill_is_capped_at_the_limit
    stub_lease
    bodies = capture_ingest_bodies

    dispatcher = configure_web_only
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }
    Timecop.freeze(Time.at(1000 + 100)) { dispatcher.send(:tick) }

    keys = bodies[1][0]["samples"].keys.map(&:to_i)
    assert_equal 1100 - HireFire::Dispatcher::WEB_BACKFILL_LIMIT, keys.min
    assert_equal 1100, keys.max
    assert_equal HireFire::Dispatcher::WEB_BACKFILL_LIMIT + 1, keys.size
  end

  def test_lease_unauthorized_does_not_log_error
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 401)

    dispatcher = configure_workers_only
    dispatcher.send(:worker_tick)
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

  def test_oversized_payload_is_dropped_without_a_request
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    dispatcher = configure_web_only

    Timecop.freeze Time.at(1000) do
      15_000.times { HireFire.configuration.buffer.sample_web(12345) }
      dispatcher.send(:tick)
    end

    assert_not_requested(:post, "https://data.hirefire.io/metrics/ingest")
    assert_empty HireFire.configuration.buffer.flush[:web]
    assert_includes log.string, "Dropped metrics payload"
  end

  def test_oversized_drop_advances_the_watermark_past_the_hole
    stub_lease
    bodies = capture_ingest_bodies

    dispatcher = configure_web_only
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }
    Timecop.freeze Time.at(1010) do
      15_000.times { HireFire.configuration.buffer.sample_web(12345) }
      dispatcher.send(:tick)
    end
    Timecop.freeze(Time.at(1012)) { dispatcher.send(:tick) }

    assert_equal 2, bodies.size
    assert_equal %w[1011 1012], bodies[1][0]["samples"].keys.sort
  end

  def test_dispatch_tick_does_not_run_worker_sampling
    stub_lease(granted: true)
    bodies = capture_ingest_bodies
    sampled = false

    Timecop.freeze Time.at(1000) do
      HireFire.configuration.dyno(:web)
      HireFire.configuration.dyno(:worker) { sampled = true }
      dispatcher = HireFire.configuration.dispatcher
      HireFire.configuration.buffer.sample_web(5)

      dispatcher.send(:tick)
    end

    assert_equal ["web"], bodies[0].map { |e| e["name"] }
    refute sampled
  end

  def test_worker_tick_samples_without_dispatching_and_a_later_tick_delivers_it
    stub_lease(granted: true)
    bodies = capture_ingest_bodies

    Timecop.freeze Time.at(1000) do
      HireFire.configuration.dyno(:worker) { 42 }
      dispatcher = HireFire.configuration.dispatcher

      dispatcher.send(:worker_tick)
      assert_empty bodies

      dispatcher.send(:tick)
    end

    assert_equal 1, bodies.size
    assert(bodies[0].any? { |e| e["name"] == "worker" && e["sample"] == 42 })
  end

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
      dispatcher.send(:worker_tick)
      dispatcher.send(:tick)
    end

    assert_requested ingest
  end

  def test_lease_granted_dispatches_workers
    stub_lease(granted: true)

    ingest = stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .with { |req|
        body = JSON.parse(req.body)
        body.any? { |e| e["name"] == "worker" && e["sample"] == 42 }
      }
      .to_return(status: 200)

    dispatcher = configure_workers_only
    dispatcher.send(:worker_tick)
    dispatcher.send(:tick)

    assert_requested ingest
  end

  def test_lease_denied_skips_worker_collection
    stub_lease

    dispatcher = configure_workers_only
    dispatcher.send(:worker_tick)
    dispatcher.send(:tick)

    assert_not_requested(:post, "https://data.hirefire.io/metrics/ingest")
  end

  def test_dispatches_cpu_samples_in_the_samples_format
    HireFire::CPU::Usage.stubs(:available_cpus).returns(1.0)
    HireFire::CPU::Usage.stubs(:reading).returns([0.0, :cgroup_v2], [0.5, :cgroup_v2])
    bodies = capture_ingest_bodies

    dispatcher = configure_cpu_only("clock")
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }
    Timecop.freeze(Time.at(1001)) { dispatcher.send(:tick) }

    assert_equal 1, bodies.size
    entry = bodies[0][0]
    assert_equal "clock", entry["name"]
    assert_equal({"1001" => [50.0]}, entry["samples"])
  end

  def test_cpu_first_tick_seeds_baseline_without_dispatching
    HireFire::CPU::Usage.stubs(:available_cpus).returns(1.0)
    HireFire::CPU::Usage.stubs(:reading).returns([0.0, :cgroup_v2])
    bodies = capture_ingest_bodies

    dispatcher = configure_cpu_only("clock")
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }

    assert_empty bodies
  end

  def test_cpu_samples_are_not_repopulated_on_dispatch_failure
    HireFire::CPU::Usage.stubs(:available_cpus).returns(1.0)
    HireFire::CPU::Usage.stubs(:reading).returns([0.0, :cgroup_v2], [0.5, :cgroup_v2])
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 500)

    dispatcher = configure_cpu_only("clock")
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }
    Timecop.freeze(Time.at(1001)) { dispatcher.send(:tick) }

    data = HireFire.configuration.buffer.flush
    assert_empty data[:cpu]
  end

  def test_non_web_process_does_not_heartbeat_the_web_name
    stub_lease
    ENV["DYNO"] = "worker.1"
    HireFire.configuration.dyno(:web)
    dispatcher = HireFire.configuration.dispatcher

    dispatcher.send(:tick)

    assert_not_requested(:post, "https://data.hirefire.io/metrics/ingest")
  end

  def test_non_web_process_still_delivers_real_web_samples
    stub_lease
    ENV["DYNO"] = "worker.1"
    HireFire.configuration.dyno(:web)
    dispatcher = HireFire.configuration.dispatcher
    bodies = capture_ingest_bodies

    Timecop.freeze(Time.at(1000)) do
      HireFire.configuration.buffer.sample_web(12)
      dispatcher.send(:tick)
    end

    assert_equal({"1000" => [12]}, bodies[0][0]["samples"])
  end

  def test_matching_identity_keeps_heartbeat_and_backfill
    stub_lease
    ENV["DYNO"] = "web.1"
    HireFire.configuration.dyno(:web)
    dispatcher = HireFire.configuration.dispatcher
    bodies = capture_ingest_bodies

    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }
    Timecop.freeze(Time.at(1002)) { dispatcher.send(:tick) }

    assert_equal({"1000" => []}, bodies[0][0]["samples"])
    assert_equal({"1001" => [], "1002" => []}, bodies[1][0]["samples"])
  end

  def test_unresolved_identity_keeps_heartbeat
    stub_lease
    HireFire.configuration.dyno(:web)
    dispatcher = HireFire.configuration.dispatcher
    bodies = capture_ingest_bodies

    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }

    assert_equal({"1000" => []}, bodies[0][0]["samples"])
  end

  def test_mismatched_cpu_collector_stays_dormant_through_the_tick
    stub_lease
    bodies = capture_ingest_bodies

    ENV["HIREFIRE_SERVICE_NAME"] = "web"
    HireFire.configuration.dyno(:web)
    HireFire.configuration.dyno(:worker, tracking: :cpu)
    dispatcher = HireFire.configuration.dispatcher

    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }

    assert_equal ["web"], bodies[0].map { |e| e["name"] }
  end

  def test_forked_child_restarts_the_dispatcher
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    dispatcher = configure_web_only
    assert dispatcher.start

    child_pid = Process.pid + 1
    Process.stubs(:pid).returns(child_pid)

    refute dispatcher.running?
    assert dispatcher.start
    assert dispatcher.running?

    dispatcher.stop
  end

  def test_forked_child_discards_inherited_buffer_samples
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    dispatcher = configure_web_only
    assert dispatcher.start

    HireFire.configuration.buffer.sample_worker("worker", 5)
    HireFire.configuration.buffer.sample_cpu("web", 12.5)

    child_pid = Process.pid + 1
    Process.stubs(:pid).returns(child_pid)

    HireFire.configuration.buffer.expects(:discard_inherited)
    assert dispatcher.start

    dispatcher.stop
  end

  def test_tick_dispatches_when_the_lease_request_fails
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_raise(Errno::ECONNREFUSED)
    bodies = capture_ingest_bodies

    Timecop.freeze Time.at(1000) do
      dispatcher = configure_web_and_workers
      HireFire.configuration.buffer.sample_web(12)
      dispatcher.send(:worker_tick)
      dispatcher.send(:tick)
    end

    assert_equal 1, bodies.size
    assert_includes log.string, "Network error"
  end

  def test_tick_dispatches_when_a_sampler_raises
    stub_lease(granted: true)
    bodies = capture_ingest_bodies

    Timecop.freeze Time.at(1000) do
      HireFire.configuration.dyno(:web)
      HireFire.configuration.dyno(:worker) { raise "Redis down" }
      dispatcher = HireFire.configuration.dispatcher
      dispatcher.send(:worker_tick)
      dispatcher.send(:tick)
    end

    assert_equal 1, bodies.size
    assert_equal ["web"], bodies[0].map { |e| e["name"] }
    assert_includes log.string, "Redis down"
  end

  def test_started_thread_dispatches_until_stopped
    dispatched = Queue.new
    stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .to_return do |_req|
        dispatched << :tick
        {status: 200}
      end

    dispatcher = configure_web_only
    dispatcher.start
    dispatched.pop
    assert dispatcher.running?

    dispatcher.stop
    refute dispatcher.running?
  end

  def test_stop_flushes_the_buffer
    bodies = capture_ingest_bodies

    dispatcher = configure_web_only
    dispatcher.instance_variable_set(:@running, true)
    dispatcher.instance_variable_set(:@pid, Process.pid)

    Timecop.freeze Time.at(1000) do
      HireFire.configuration.buffer.sample_web(7)
      dispatcher.stop
    end

    assert_equal 1, bodies.size
    assert_equal({"1000" => [7]}, bodies[0][0]["samples"])
  end

  def test_stop_closes_the_persistent_connections
    dispatcher = configure_workers_only
    dispatcher.instance_variable_get(:@client).expects(:close)
    dispatcher.instance_variable_get(:@lease).expects(:close)

    dispatcher.instance_variable_set(:@running, true)
    dispatcher.instance_variable_set(:@pid, Process.pid)
    dispatcher.stop
  end

  def test_web_only_dispatch_never_requests_a_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    dispatcher = configure_web_only
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }

    assert_not_requested(:post, "https://data.hirefire.io/metrics/lease")
  end

  def stub_ingest_with_dispatch_frequency(value)
    stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .to_return(status: 200, headers: {"HireFire-Dispatch-Frequency" => value.to_s})
  end

  def test_dispatch_frequency_defaults_to_one_without_the_header
    stub_lease
    bodies = capture_ingest_bodies

    dispatcher = configure_web_only
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }
    Timecop.freeze(Time.at(1001)) { dispatcher.send(:tick) }

    assert_equal 2, bodies.size
  end

  def test_honors_a_server_supplied_dispatch_frequency
    stub_lease
    stub_ingest_with_dispatch_frequency(5)

    dispatcher = configure_web_only
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }
    Timecop.freeze(Time.at(1002)) { dispatcher.send(:tick) }
    Timecop.freeze(Time.at(1004)) { dispatcher.send(:tick) }
    Timecop.freeze(Time.at(1005)) { dispatcher.send(:tick) }

    assert_requested(:post, "https://data.hirefire.io/metrics/ingest", times: 2)
  end

  def test_clamps_an_over_large_dispatch_frequency_to_the_maximum
    stub_lease
    stub_ingest_with_dispatch_frequency(HireFire::Dispatcher::MAX_DISPATCH_FREQUENCY + 100)

    dispatcher = configure_web_only
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }

    assert_equal HireFire::Dispatcher::MAX_DISPATCH_FREQUENCY,
      dispatcher.instance_variable_get(:@dispatch_frequency)
  end

  def test_ignores_a_non_positive_dispatch_frequency
    stub_lease
    stub_ingest_with_dispatch_frequency(0)

    dispatcher = configure_web_only
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }

    assert_equal HireFire::Dispatcher::DEFAULT_DISPATCH_FREQUENCY,
      dispatcher.instance_variable_get(:@dispatch_frequency)
  end

  def test_ignores_an_unparseable_dispatch_frequency
    stub_lease
    stub_ingest_with_dispatch_frequency("nonsense")

    dispatcher = configure_web_only
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }

    assert_equal HireFire::Dispatcher::DEFAULT_DISPATCH_FREQUENCY,
      dispatcher.instance_variable_get(:@dispatch_frequency)
  end

  def test_dispatch_failure_without_web_data_does_not_repopulate
    stub_lease(granted: true)
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 500)

    dispatcher = configure_workers_only
    dispatcher.send(:worker_tick)
    dispatcher.send(:tick)

    assert_empty HireFire.configuration.buffer.flush[:web]
    assert_includes log.string, "Dispatch error"
  end

  def test_dispatch_pacing_follows_the_monotonic_clock_not_the_wall_clock
    stub_lease
    bodies = capture_ingest_bodies

    dispatcher = configure_web_only
    HireFire::Clock.stubs(:monotonic).returns(500.0, 502.0, 502.0)

    Timecop.freeze(Time.at(1000)) do
      dispatcher.send(:tick)
      dispatcher.send(:tick)
    end

    assert_equal 2, bodies.size
  end
end
