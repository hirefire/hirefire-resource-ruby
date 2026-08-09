# frozen_string_literal: true

require "test_helper"
require "timeout"

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

  def stub_lease(granted: false, job_queues: nil)
    body = if job_queues.nil?
      if granted
        {version: 1, job_queues: [
          {"name" => "worker", "strategy" => "jql", "adapter" => nil, "queues" => [], "options" => {}},
          {"name" => "mailer", "strategy" => "jql", "adapter" => nil, "queues" => [], "options" => {}}
        ]}.to_json
      else
        ""
      end
    else
      {version: 1, job_queues: job_queues}.to_json
    end

    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => granted.to_s,
        "HireFire-Sample-Frequency" => "15"
      }, body: body)
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
    ENV["DYNO"] ||= "web.1"
    HireFire.configuration.dyno(:web)
    HireFire.configuration.dyno(:worker) { 42 }
    HireFire.configuration.dyno(:mailer) { 18 }
    HireFire.configuration.dispatcher
  end

  def configure_web_only
    ENV["DYNO"] ||= "web.1"
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
          body[0].dig("metrics", "rqt") and body[0]["metrics"]["rqt"].values.first == [10.0, 2]
      }
      .to_return(status: 200)

    dispatcher = configure_web_only

    Timecop.freeze Time.at(1000) do
      HireFire.configuration.buffer.sample("web", "rqt", 12)
      HireFire.configuration.buffer.sample("web", "rqt", 8)
      dispatcher.send(:tick)
    end

    assert_requested request
  end

  def test_dispatches_jqs_and_wrk_as_sibling_bare_numbers
    stub_lease
    bodies = capture_ingest_bodies
    dispatcher = configure_workers_only

    Timecop.freeze Time.at(2500) do
      HireFire.configuration.buffer.sample("worker", "jqs", 12)
      HireFire.configuration.buffer.sample("worker", "wrk", 3)
      dispatcher.send(:dispatch)
    end

    assert bodies.any?, "expected an ingest POST"
    entry = bodies.last.find { |e| e["name"] == "worker" }
    refute_nil entry
    jqs_leaf = entry.dig("metrics", "jqs", "2500")
    wrk_leaf = entry.dig("metrics", "wrk", "2500")
    assert_equal 12, jqs_leaf
    assert_equal 3, wrk_leaf
    assert_kind_of Numeric, jqs_leaf
    assert_kind_of Numeric, wrk_leaf
    refute_kind_of Array, wrk_leaf, "wrk must be bare number like jqs, not rqt [v,n]"
  end

  def test_logs_the_payload_when_verbose_is_set
    ENV["HIREFIRE_VERBOSE"] = "1"
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    dispatcher = configure_web_only

    Timecop.freeze Time.at(1000) do
      HireFire.configuration.buffer.sample("web", "rqt", 12)
      dispatcher.send(:tick)
    end

    assert_includes log.string, "Dispatching metrics"
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

    assert_equal({"1000" => []}, bodies[0][0].dig("metrics", "rqt"))
  end

  def test_backfills_seconds_skipped_between_dispatches
    stub_lease
    bodies = capture_ingest_bodies

    dispatcher = configure_web_only
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }
    Timecop.freeze(Time.at(1003)) { dispatcher.send(:tick) }

    assert_equal({"1001" => [], "1002" => [], "1003" => []}, bodies[1][0].dig("metrics", "rqt"))
  end

  def test_backfill_preserves_buffered_samples
    stub_lease
    bodies = capture_ingest_bodies

    dispatcher = configure_web_only
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }
    Timecop.freeze(Time.at(1003)) do
      HireFire.configuration.buffer.sample("web", "rqt", 5)
      dispatcher.send(:tick)
    end

    assert_equal({"1001" => [], "1002" => [], "1003" => [5.0, 1]}, bodies[1][0].dig("metrics", "rqt"))
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

    assert_equal %w[1001 1002 1003 1004 1005], bodies[2][0].dig("metrics", "rqt").keys.sort
  end

  def test_backfill_is_capped_at_the_limit
    stub_lease
    bodies = capture_ingest_bodies

    dispatcher = configure_web_only
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }
    Timecop.freeze(Time.at(1000 + 100)) { dispatcher.send(:tick) }

    keys = bodies[1][0].dig("metrics", "rqt").keys.map(&:to_i)
    assert_equal 1100 - HireFire::Dispatcher::RQT_BACKFILL_LIMIT, keys.min
    assert_equal 1100, keys.max
    assert_equal HireFire::Dispatcher::RQT_BACKFILL_LIMIT + 1, keys.size
  end

  def test_lease_unauthorized_does_not_log_error
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 401)

    dispatcher = configure_workers_only
    dispatcher.send(:job_queue_tick)
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
      HireFire.configuration.buffer.sample("web", "rqt", 7)
      dispatcher.send(:tick)
    end

    data = HireFire.configuration.buffer.flush
    assert_nil data.dig("web", "rqt")
    refute_includes log.string, "Dispatch error"
  end

  def test_web_buffer_repopulated_on_dispatch_failure
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .to_return(status: 500)

    dispatcher = configure_web_only

    Timecop.freeze Time.at(1000) do
      HireFire.configuration.buffer.sample("web", "rqt", 7)
      dispatcher.send(:tick)
    end

    data = HireFire.configuration.buffer.flush
    assert_equal({sum: 7.0, count: 1}, data.dig("web", "rqt", 1000))
  end

  def test_oversized_payload_is_dropped_without_a_request
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    dispatcher = configure_web_only

    Timecop.freeze Time.at(1000) do
      inject_oversized_series("web", "rqt")
      dispatcher.send(:tick)
    end

    assert_not_requested(:post, "https://data.hirefire.io/metrics/ingest")
    assert_nil HireFire.configuration.buffer.flush.dig("web", "rqt")
    assert_includes log.string, "Dropped metrics payload"
  end

  def test_oversized_drop_advances_the_watermark_past_the_hole
    stub_lease
    bodies = capture_ingest_bodies

    dispatcher = configure_web_only
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }
    Timecop.freeze Time.at(1010) do
      inject_oversized_series("web", "rqt")
      dispatcher.send(:tick)
    end
    Timecop.freeze(Time.at(1012)) { dispatcher.send(:tick) }

    assert_equal 2, bodies.size
    assert_equal %w[1011 1012], bodies[1][0].dig("metrics", "rqt").keys.sort
  end

  def test_an_oversized_payload_without_web_data_drops_without_touching_the_watermark
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    dispatcher = HireFire.configuration.dispatcher

    Timecop.freeze Time.at(1000) do
      inject_oversized_series("worker", "jql")
      dispatcher.send(:tick)
    end

    assert_not_requested(:post, "https://data.hirefire.io/metrics/ingest")
    assert_includes log.string, "Dropped metrics payload"
    assert_nil dispatcher.instance_variable_get(:@last_rqt_second)
  end

  def test_dispatch_tick_does_not_run_job_queue_sampling
    stub_lease(granted: true)
    bodies = capture_ingest_bodies
    sampled = false

    Timecop.freeze Time.at(1000) do
      HireFire.configuration.dyno(:web)
      HireFire.configuration.dyno(:worker) { sampled = true }
      dispatcher = HireFire.configuration.dispatcher
      HireFire.configuration.buffer.sample("web", "rqt", 5)

      dispatcher.send(:tick)
    end

    assert_equal ["web"], bodies[0].map { |e| e["name"] }
    refute sampled
  end

  def test_job_queue_tick_samples_without_dispatching_and_a_later_tick_delivers_it
    stub_lease(granted: true)
    bodies = capture_ingest_bodies

    Timecop.freeze Time.at(1000) do
      HireFire.configuration.dyno(:worker) { 42 }
      dispatcher = HireFire.configuration.dispatcher

      dispatcher.send(:job_queue_tick)
      assert_empty bodies

      dispatcher.send(:tick)
    end

    assert_equal 1, bodies.size
    assert(bodies[0].any? { |e| e["name"] == "worker" && e.dig("metrics", "jql", "1000") == 42 })
  end

  def test_combined_web_and_worker_dispatch
    stub_lease(granted: true)

    ingest = stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .with { |req|
        body = JSON.parse(req.body)
        has_web = body.any? { |e| e["name"] == "web" && e.dig("metrics", "rqt") }
        has_worker = body.any? { |e| e["name"] == "worker" && e.dig("metrics", "jql") }
        has_web && has_worker
      }
      .to_return(status: 200)

    Timecop.freeze Time.at(1000) do
      dispatcher = configure_web_and_workers
      HireFire.configuration.buffer.sample("web", "rqt", 5)
      dispatcher.send(:job_queue_tick)
      dispatcher.send(:tick)
    end

    assert_requested ingest
  end

  def test_lease_granted_dispatches_workers
    stub_lease(granted: true)

    ingest = stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .with { |req|
        body = JSON.parse(req.body)
        body.any? { |e| e["name"] == "worker" && e.dig("metrics", "jql") }
      }
      .to_return(status: 200)

    dispatcher = configure_workers_only
    dispatcher.send(:job_queue_tick)
    dispatcher.send(:tick)

    assert_requested ingest
  end

  def test_lease_denied_skips_worker_collection
    stub_lease

    dispatcher = configure_workers_only
    dispatcher.send(:job_queue_tick)
    dispatcher.send(:tick)

    assert_not_requested(:post, "https://data.hirefire.io/metrics/ingest")
  end

  def test_dispatches_cpu_samples_in_the_nested_format
    HireFire::Source::CPU::Usage.stubs(:available_cpus).returns(1.0)
    HireFire::Source::CPU::Usage.stubs(:reading).returns([0.0, :cgroup_v2], [0.5, :cgroup_v2])
    bodies = capture_ingest_bodies

    dispatcher = configure_cpu_only("clock")
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }
    Timecop.freeze(Time.at(1001)) { dispatcher.send(:tick) }

    assert_equal 1, bodies.size
    entry = bodies[0][0]
    assert_equal "clock", entry["name"]
    assert_equal({"1001" => 50.0}, entry.dig("metrics", "cpu"))
  end

  def test_cpu_first_tick_seeds_baseline_without_dispatching
    HireFire::Source::CPU::Usage.stubs(:available_cpus).returns(1.0)
    HireFire::Source::CPU::Usage.stubs(:reading).returns([0.0, :cgroup_v2])
    bodies = capture_ingest_bodies

    dispatcher = configure_cpu_only("clock")
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }

    assert_empty bodies
  end

  def test_cpu_samples_are_not_repopulated_on_dispatch_failure
    HireFire::Source::CPU::Usage.stubs(:available_cpus).returns(1.0)
    HireFire::Source::CPU::Usage.stubs(:reading).returns([0.0, :cgroup_v2], [0.5, :cgroup_v2])
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 500)

    dispatcher = configure_cpu_only("clock")
    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }
    Timecop.freeze(Time.at(1001)) { dispatcher.send(:tick) }

    data = HireFire.configuration.buffer.flush
    assert_nil data.dig("clock", "cpu")
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
      HireFire.configuration.buffer.sample("web", "rqt", 12)
      dispatcher.send(:tick)
    end

    assert_equal({"1000" => [12.0, 1]}, bodies[0][0].dig("metrics", "rqt"))
  end

  def test_matching_identity_keeps_heartbeat_and_backfill
    stub_lease
    ENV["DYNO"] = "web.1"
    HireFire.configuration.dyno(:web)
    dispatcher = HireFire.configuration.dispatcher
    bodies = capture_ingest_bodies

    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }
    Timecop.freeze(Time.at(1002)) { dispatcher.send(:tick) }

    assert_equal({"1000" => []}, bodies[0][0].dig("metrics", "rqt"))
    assert_equal({"1001" => [], "1002" => []}, bodies[1][0].dig("metrics", "rqt"))
  end

  def test_unresolved_identity_does_not_synthesize_liveness
    stub_lease
    HireFire.configuration.dyno(:web)
    dispatcher = HireFire.configuration.dispatcher
    bodies = capture_ingest_bodies

    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }

    assert_empty bodies
  end

  def test_always_on_cpu_uses_identity_name_through_the_tick
    HireFire::Source::CPU::Usage.stubs(:available_cpus).returns(1.0)
    HireFire::Source::CPU::Usage.stubs(:reading).returns([0.0, :cgroup_v2], [0.5, :cgroup_v2])
    stub_lease
    bodies = capture_ingest_bodies

    ENV["HIREFIRE_SERVICE_NAME"] = "web"
    dispatcher = HireFire.configuration.dispatcher

    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }
    Timecop.freeze(Time.at(1001)) { dispatcher.send(:tick) }

    # First tick establishes the CPU baseline (no sample). Second tick dispatches cpu.
    entry = bodies.flat_map { |b| b }.find { |e| e["name"] == "web" }
    assert entry
    assert entry.dig("metrics", "cpu")
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

    HireFire.configuration.buffer.sample("web", "rqt", 7)
    HireFire.configuration.buffer.sample("worker", "jql", 5)
    HireFire.configuration.buffer.sample("web", "cpu", 12.5)

    child_pid = Process.pid + 1
    Process.stubs(:pid).returns(child_pid)

    assert dispatcher.start

    assert_empty HireFire.configuration.buffer.flush

    dispatcher.stop
  end

  def test_tick_dispatches_when_the_lease_request_fails
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_raise(Errno::ECONNREFUSED)
    bodies = capture_ingest_bodies

    Timecop.freeze Time.at(1000) do
      dispatcher = configure_web_and_workers
      HireFire.configuration.buffer.sample("web", "rqt", 12)
      dispatcher.send(:job_queue_tick)
      dispatcher.send(:tick)
    end

    assert_equal 1, bodies.size
    assert_includes log.string, "Network error"
  end

  def test_tick_dispatches_when_a_sampler_raises
    stub_lease(granted: true)
    bodies = capture_ingest_bodies

    Timecop.freeze Time.at(1000) do
      ENV["DYNO"] = "web.1"
      HireFire.configuration.dyno(:web)
      HireFire.configuration.dyno(:worker) { raise "Redis down" }
      dispatcher = HireFire.configuration.dispatcher
      dispatcher.send(:job_queue_tick)
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
    item = begin
      dispatched.pop(true)
    rescue ThreadError
      Timeout.timeout(3) { dispatched.pop }
    end
    assert_equal :tick, item
    assert dispatcher.running?

    dispatcher.stop
    refute dispatcher.running?
  end

  def test_stale_loop_generation_stops_after_restart
    dispatcher = configure_web_only
    generation = 1
    dispatcher.instance_variable_set(:@running, true)
    dispatcher.instance_variable_set(:@pid, Process.pid)
    dispatcher.instance_variable_set(:@generation, generation)

    assert dispatcher.send(:loop_active?, generation)

    dispatcher.instance_variable_set(:@running, false)
    dispatcher.instance_variable_set(:@pid, nil)
    refute dispatcher.send(:loop_active?, generation)

    dispatcher.instance_variable_set(:@generation, 2)
    dispatcher.instance_variable_set(:@running, true)
    dispatcher.instance_variable_set(:@pid, Process.pid)
    refute dispatcher.send(:loop_active?, generation)
    assert dispatcher.send(:loop_active?, 2)
  end

  def test_stale_generation_cannot_dispatch_after_restart
    bodies = []
    stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .to_return do |request|
        bodies << JSON.parse(request.body)
        {status: 200}
      end

    dispatcher = configure_web_only
    dispatcher.instance_variable_set(:@running, true)
    dispatcher.instance_variable_set(:@pid, Process.pid)
    dispatcher.instance_variable_set(:@generation, 2)

    HireFire.configuration.buffer.sample("web", "rqt", 99)
    # Stale loop still holds a pre-restart generation and must not dispatch.
    dispatcher.send(:loop_until_stopped, 1) { dispatcher.send(:tick) }

    assert_empty bodies
    dispatcher.instance_variable_set(:@running, false)
    dispatcher.instance_variable_set(:@pid, nil)
  end

  def test_a_hung_worker_sampler_does_not_stall_web_dispatch
    stub_lease(granted: true)
    sampler_gate = Queue.new
    web_dispatched = Queue.new
    worker_dispatched = Queue.new

    stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .to_return do |request|
        body = JSON.parse(request.body)
        web_dispatched << body if body.any? { |e| e["name"] == "web" }
        worker_dispatched << body if body.any? { |e| e["name"] == "worker" }
        {status: 200}
      end

    HireFire.configuration.dyno(:web)
    HireFire.configuration.dyno(:worker) { sampler_gate.pop }
    dispatcher = HireFire.configuration.dispatcher
    HireFire.configuration.buffer.sample("web", "rqt", 5)

    dispatcher.start
    body = Timeout.timeout(3) { web_dispatched.pop }

    assert(body.any? { |e| e["name"] == "web" })
    assert_raises(ThreadError) { worker_dispatched.pop(true) }

    sampler_gate << 0
    Timeout.timeout(3) { worker_dispatched.pop }
    dispatcher.stop
  end

  def test_stop_flushes_the_buffer
    bodies = capture_ingest_bodies

    dispatcher = configure_web_only
    dispatcher.instance_variable_set(:@running, true)
    dispatcher.instance_variable_set(:@pid, Process.pid)

    Timecop.freeze Time.at(1000) do
      HireFire.configuration.buffer.sample("web", "rqt", 7)
      dispatcher.stop
    end

    assert_equal 1, bodies.size
    assert_equal({"1000" => [7.0, 1]}, bodies[0][0].dig("metrics", "rqt"))
  end

  def test_stop_without_flush_skips_final_dispatch
    bodies = capture_ingest_bodies

    dispatcher = configure_web_only
    dispatcher.instance_variable_set(:@running, true)
    dispatcher.instance_variable_set(:@pid, Process.pid)

    HireFire.configuration.buffer.sample("web", "rqt", 7)
    assert dispatcher.stop(flush: false)

    assert_empty bodies
    refute dispatcher.running?
  end

  def test_stop_returns_within_join_timeout_when_job_sampler_hangs
    stub_lease(granted: true)
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    gate = Queue.new
    HireFire.configuration.dyno(:worker) { gate.pop }
    dispatcher = HireFire.configuration.dispatcher
    assert dispatcher.start

    # Let the job-queue loop enter the hanging sampler.
    sleep 0.2

    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert dispatcher.stop
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, HireFire::Dispatcher::JOIN_TIMEOUT + 2,
      "stop must not wait unbounded on a hung job-queue sampler"
    assert_includes log.string, "Abandoning thread"
  ensure
    gate << 0 if defined?(gate)
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
    dispatcher.send(:job_queue_tick)
    dispatcher.send(:tick)

    assert_nil HireFire.configuration.buffer.flush.dig("web", "rqt")
    assert_includes log.string, "Dispatch error"
  end

  def test_tick_survives_a_payload_build_error
    stub_lease
    HireFire.configuration.buffer.stubs(:flush).raises(RuntimeError.new("boom"))

    dispatcher = configure_web_only
    dispatcher.send(:tick)

    assert_includes log.string, "Dispatch error"
  end

  def test_dispatch_pacing_follows_the_monotonic_clock_not_the_wall_clock
    stub_lease
    bodies = capture_ingest_bodies

    dispatcher = configure_web_only
    # Enough values for CPU sample + dispatch pacing across two ticks.
    HireFire::Clock.stubs(:monotonic).returns(
      500.0, 500.0, 500.0,
      502.0, 502.0, 502.0,
      502.0, 502.0, 502.0
    )

    Timecop.freeze(Time.at(1000)) do
      dispatcher.send(:tick)
      dispatcher.send(:tick)
    end

    assert_equal 2, bodies.size
  end

  def test_nested_payload_merges_rqt_and_cpu_under_one_name
    ENV["DYNO"] = "web.1"
    HireFire::Source::CPU::Usage.stubs(:available_cpus).returns(1.0)
    HireFire::Source::CPU::Usage.stubs(:reading).returns([0.0, :cgroup_v2], [0.5, :cgroup_v2])
    bodies = capture_ingest_bodies

    HireFire.configuration.dyno(:web)
    dispatcher = HireFire.configuration.dispatcher

    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }
    Timecop.freeze(Time.at(1001)) do
      HireFire.configuration.buffer.sample("web", "rqt", 12)
      dispatcher.send(:tick)
    end

    entry = bodies.last.find { |e| e["name"] == "web" }
    assert entry.dig("metrics", "rqt")
    assert entry.dig("metrics", "cpu")
  end

  def test_always_lease_non_renew_when_no_workers_and_no_executable_plan
    HireFire::Plan.stubs(:any_allowlisted_job_queue_library_loaded?).returns(true)
    HireFire::Plan.stubs(:executable?).returns(false)
    HireFire::Plan.stubs(:known_adapter?).returns(true)

    stub_lease(granted: true, job_queues: [
      {"name" => "worker", "strategy" => "jql", "adapter" => "sidekiq", "queues" => [], "options" => {}}
    ])

    dispatcher = HireFire.configuration.dispatcher
    assert dispatcher.send(:enter_race?)

    dispatcher.send(:job_queue_tick)
    refute dispatcher.instance_variable_get(:@lease).granted?
  end

  def test_plan_adapter_overrides_local_sampler
    mod = Module.new
    mod.extend(HireFire::Plan::Hooks)
    mod.define_singleton_method(:job_queue_latency) { |*_queues, **_options| 9.9 }

    original = HireFire::Plan::ADAPTERS
    original_checks = HireFire::Plan::LIBRARY_CHECKS
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original.merge("sidekiq" => mod))
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks.merge("sidekiq" => -> { true }))

    stub_lease(granted: true, job_queues: [
      {"name" => "worker", "strategy" => "jql", "adapter" => "sidekiq", "queues" => ["default"], "options" => {}}
    ])
    bodies = capture_ingest_bodies

    HireFire.configuration.dyno(:worker) { 1 }
    dispatcher = HireFire.configuration.dispatcher
    dispatcher.send(:job_queue_tick)
    dispatcher.send(:tick)

    entry = bodies[0].find { |e| e["name"] == "worker" }
    assert_equal 9.9, entry.dig("metrics", "jql").values.first
  ensure
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original)
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks)
  end

  def test_strategy_only_plan_uses_local_sampler
    stub_lease(granted: true, job_queues: [
      {"name" => "worker", "strategy" => "jqs", "adapter" => nil, "queues" => [], "options" => {}}
    ])
    bodies = capture_ingest_bodies

    HireFire.configuration.dyno(:worker) { 7 }
    dispatcher = HireFire.configuration.dispatcher
    dispatcher.send(:job_queue_tick)
    dispatcher.send(:tick)

    entry = bodies[0].find { |e| e["name"] == "worker" }
    assert_equal 7, entry.dig("metrics", "jqs").values.first
    refute_includes log.string, "UI adapter is configured"
  end

  def test_unknown_plan_adapter_skips_without_local_fallback
    stub_lease(granted: true, job_queues: [
      {"name" => "worker", "strategy" => "jql", "adapter" => "nope", "queues" => [], "options" => {}}
    ])
    bodies = capture_ingest_bodies

    HireFire.configuration.dyno(:worker) { 42 }
    dispatcher = HireFire.configuration.dispatcher
    dispatcher.send(:job_queue_tick)
    dispatcher.send(:tick)

    assert_empty bodies
    assert_includes log.string, "Unknown plan adapter"
  end

  def test_known_unloaded_adapter_skips_without_local_fallback
    HireFire::Plan.stubs(:executable?).with("sidekiq").returns(false)
    HireFire::Plan.stubs(:known_adapter?).with("sidekiq").returns(true)

    stub_lease(granted: true, job_queues: [
      {"name" => "worker", "strategy" => "jql", "adapter" => "sidekiq", "queues" => [], "options" => {}}
    ])
    bodies = capture_ingest_bodies

    HireFire.configuration.dyno(:worker) { 42 }
    dispatcher = HireFire.configuration.dispatcher
    dispatcher.send(:job_queue_tick)
    dispatcher.send(:job_queue_tick)
    dispatcher.send(:tick)

    assert_empty bodies
    assert_equal 1, log.string.scan("is not loaded in this process").size
  end

  def test_unsupported_plan_strategy_logs_once_and_skips_macro
    calls = 0
    mod = Module.new
    mod.extend(HireFire::Plan::Hooks)
    mod.extend(HireFire::Errors::JobQueueLatencyUnsupported)
    mod.define_singleton_method(:job_queue_size) { |*_queues, **_options| 1 }
    mod.define_singleton_method(:job_queue_latency) do |*_queues, **_options|
      calls += 1
      raise "should not be called"
    end

    original = HireFire::Plan::ADAPTERS
    original_checks = HireFire::Plan::LIBRARY_CHECKS
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original.merge("bunny" => mod))
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks.merge("bunny" => -> { true }))

    stub_lease(granted: true, job_queues: [
      {"name" => "worker", "strategy" => "jql", "adapter" => "bunny", "queues" => ["default"], "options" => {}}
    ])
    bodies = capture_ingest_bodies

    # Local sampler keeps the grant so the plan path still runs (unsupported
    # strategy alone would demote and never sample).
    HireFire.configuration.dyno(:other) { 0 }
    dispatcher = HireFire.configuration.dispatcher
    dispatcher.send(:job_queue_tick)
    dispatcher.send(:job_queue_tick)
    dispatcher.send(:tick)

    assert_equal 0, calls
    assert_equal 1, log.string.scan("does not support").size
    refute bodies.any? { |body| body.any? { |e| e["name"] == "worker" } }
  ensure
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original)
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks)
  end

  def test_hold_lease_false_when_only_unsupported_strategy_entries
    HireFire::Plan.stubs(:any_allowlisted_job_queue_library_loaded?).returns(true)
    HireFire::Plan.stubs(:executable?).with("bunny").returns(true)
    HireFire::Plan.stubs(:supports_strategy?).with("bunny", "jql").returns(false)

    stub_lease(granted: true, job_queues: [
      {"name" => "worker", "strategy" => "jql", "adapter" => "bunny", "queues" => ["default"], "options" => {}}
    ])

    dispatcher = HireFire.configuration.dispatcher
    assert dispatcher.send(:enter_race?)

    dispatcher.send(:job_queue_tick)
    refute dispatcher.instance_variable_get(:@lease).granted?
  end

  def test_start_rejected_while_stopping
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    dispatcher = configure_web_only
    assert dispatcher.start

    dispatcher.instance_variable_set(:@stopping, true)
    refute dispatcher.start

    dispatcher.instance_variable_set(:@stopping, false)
    dispatcher.stop
  end

  def test_concurrent_start_during_stop_is_rejected_then_retryable
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    dispatcher = configure_web_only
    assert dispatcher.start
    assert dispatcher.running?

    stop_done = Queue.new
    start_results = Queue.new

    Thread.new do
      dispatcher.stop
      stop_done << true
    end

    starters = 8.times.map do
      Thread.new do
        # Contended with stop: must not leave a half-running dispatcher.
        start_results << dispatcher.start
      end
    end

    Timeout.timeout(5) { stop_done.pop }
    starters.each(&:join)
    results = []
    results << start_results.pop until start_results.empty?

    refute dispatcher.running?
    # After stop finishes, start must work again.
    assert dispatcher.start
    assert dispatcher.running?
    dispatcher.stop
  end

  def test_fork_resets_dispatch_pacing_and_watermark
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    dispatcher = configure_web_only
    assert dispatcher.start
    dispatcher.instance_variable_set(:@next_dispatch_at, 1_000_000.0)
    dispatcher.instance_variable_set(:@last_rqt_second, 1_700_000_000)

    child_pid = dispatcher.instance_variable_get(:@pid) + 1
    Process.stubs(:pid).returns(child_pid)
    assert dispatcher.start

    assert_nil dispatcher.instance_variable_get(:@next_dispatch_at)
    assert_nil dispatcher.instance_variable_get(:@last_rqt_second)

    dispatcher.stop
  end

  def test_executable_plan_without_local_dyno_holds_lease_and_samples
    mod = Module.new
    mod.extend(HireFire::Plan::Hooks)
    mod.define_singleton_method(:job_queue_latency) { |*_queues, **_options| 4.2 }

    original = HireFire::Plan::ADAPTERS
    original_checks = HireFire::Plan::LIBRARY_CHECKS
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original.merge("sidekiq" => mod))
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks.merge("sidekiq" => -> { true }))
    HireFire::Plan.stubs(:any_allowlisted_job_queue_library_loaded?).returns(true)

    stub_lease(granted: true, job_queues: [
      {"name" => "worker", "strategy" => "jql", "adapter" => "sidekiq", "queues" => ["default"], "options" => {}}
    ])
    bodies = capture_ingest_bodies

    dispatcher = HireFire.configuration.dispatcher
    assert dispatcher.send(:enter_race?)
    refute HireFire.configuration.job_queues.any?

    dispatcher.send(:job_queue_tick)
    assert dispatcher.instance_variable_get(:@lease).granted?
    dispatcher.send(:tick)

    entry = bodies[0].find { |e| e["name"] == "worker" }
    assert_equal 4.2, entry.dig("metrics", "jql").values.first
    refute_includes log.string, "local sampler is ignored"
    refute_includes log.string, "UI adapter is configured"
  ensure
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original)
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks)
  end

  def test_plan_override_warns_once
    mod = Module.new
    mod.extend(HireFire::Plan::Hooks)
    mod.define_singleton_method(:job_queue_latency) { |*_queues, **_options| 1.0 }

    original = HireFire::Plan::ADAPTERS
    original_checks = HireFire::Plan::LIBRARY_CHECKS
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original.merge("sidekiq" => mod))
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks.merge("sidekiq" => -> { true }))

    stub_lease(granted: true, job_queues: [
      {"name" => "worker", "strategy" => "jql", "adapter" => "sidekiq", "queues" => [], "options" => {}}
    ])

    HireFire.configuration.dyno(:worker) { 99 }
    dispatcher = HireFire.configuration.dispatcher
    dispatcher.send(:job_queue_tick)
    dispatcher.send(:job_queue_tick)

    assert_equal 1, log.string.scan("UI adapter is configured").size
    assert_includes log.string, "config.dyno"
    assert_includes log.string, "You can remove"
  ensure
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original)
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks)
  end

  def test_strategy_only_unknown_strategy_skips_and_logs
    stub_lease(granted: true, job_queues: [
      {"name" => "worker", "strategy" => "rpm", "adapter" => nil, "queues" => [], "options" => {}}
    ])
    bodies = capture_ingest_bodies

    HireFire.configuration.dyno(:worker) { 7 }
    dispatcher = HireFire.configuration.dispatcher
    dispatcher.send(:job_queue_tick)
    dispatcher.send(:tick)

    assert_empty bodies
    assert_includes log.string, "Unknown plan strategy"
  end

  def test_empty_string_adapter_uses_local_strategy_sampler
    stub_lease(granted: true, job_queues: [
      {"name" => "worker", "strategy" => "jqs", "adapter" => "", "queues" => [], "options" => {}}
    ])
    bodies = capture_ingest_bodies

    HireFire.configuration.dyno(:worker) { 11 }
    dispatcher = HireFire.configuration.dispatcher
    dispatcher.send(:job_queue_tick)
    dispatcher.send(:tick)

    entry = bodies[0].find { |e| e["name"] == "worker" }
    assert_equal 11, entry.dig("metrics", "jqs").values.first
  end

  def test_jql_not_repopulated_on_dispatch_failure
    stub_lease(granted: true)
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 500)

    Timecop.freeze Time.at(1000) do
      HireFire.configuration.dyno(:worker) { 3 }
      dispatcher = HireFire.configuration.dispatcher
      dispatcher.send(:job_queue_tick)
      dispatcher.send(:tick)

      assert_empty HireFire.configuration.buffer.flush
      assert_includes log.string, "Dispatch error"
    end
  end

  def test_empty_plan_with_local_samplers_still_holds_lease
    stub_lease(granted: true, job_queues: [])
    HireFire.configuration.dyno(:worker) { 5 }
    dispatcher = HireFire.configuration.dispatcher

    dispatcher.send(:job_queue_tick)
    assert dispatcher.instance_variable_get(:@lease).granted?
  end

  def test_partial_plan_holds_and_samples_only_executable_entries
    mod = Module.new
    mod.extend(HireFire::Plan::Hooks)
    mod.define_singleton_method(:job_queue_latency) { |*_queues, **_options| 2.5 }

    original = HireFire::Plan::ADAPTERS
    original_checks = HireFire::Plan::LIBRARY_CHECKS
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original.merge("sidekiq" => mod))
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks.merge(
      "sidekiq" => -> { true },
      "resque" => -> { false }
    ))
    HireFire::Plan.stubs(:any_allowlisted_job_queue_library_loaded?).returns(true)

    stub_lease(granted: true, job_queues: [
      {"name" => "worker", "strategy" => "jql", "adapter" => "sidekiq", "queues" => [], "options" => {}},
      {"name" => "mailer", "strategy" => "jql", "adapter" => "resque", "queues" => [], "options" => {}}
    ])
    bodies = capture_ingest_bodies

    dispatcher = HireFire.configuration.dispatcher
    dispatcher.send(:job_queue_tick)
    assert dispatcher.instance_variable_get(:@lease).granted?
    dispatcher.send(:tick)

    assert(bodies[0].any? { |e| e["name"] == "worker" })
    refute(bodies[0].any? { |e| e["name"] == "mailer" })
    assert_includes log.string, "is not loaded in this process"
  ensure
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original)
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks)
  end

  def test_hold_demotion_logs_and_web_dispatch_continues
    HireFire::Plan.stubs(:any_allowlisted_job_queue_library_loaded?).returns(true)
    HireFire::Plan.stubs(:executable?).returns(false)
    HireFire::Plan.stubs(:known_adapter?).returns(true)

    stub_lease(granted: true, job_queues: [
      {"name" => "worker", "strategy" => "jql", "adapter" => "sidekiq", "queues" => [], "options" => {}}
    ])
    bodies = capture_ingest_bodies

    ENV["DYNO"] = "web.1"
    HireFire.configuration.dyno(:web)
    dispatcher = HireFire.configuration.dispatcher
    HireFire.configuration.buffer.sample("web", "rqt", 8)

    dispatcher.send(:job_queue_tick)
    refute dispatcher.instance_variable_get(:@lease).granted?
    assert_includes log.string, "Lease grant dropped"

    Timecop.freeze(Time.at(1000)) { dispatcher.send(:tick) }
    assert_equal 1, bodies.size
    assert(bodies[0].any? { |e| e["name"] == "web" })
  end

  def test_ensure_job_queue_loop_is_noop_when_not_running
    dispatcher = configure_web_only
    dispatcher.ensure_job_queue_loop
    assert_nil dispatcher.instance_variable_get(:@job_queue_thread)
  end

  def test_ensure_job_queue_loop_is_noop_when_stopping
    dispatcher = configure_workers_only
    dispatcher.instance_variable_set(:@running, true)
    dispatcher.instance_variable_set(:@pid, Process.pid)
    dispatcher.instance_variable_set(:@stopping, true)
    dispatcher.ensure_job_queue_loop
    assert_nil dispatcher.instance_variable_get(:@job_queue_thread)
  end

  def test_ensure_job_queue_loop_is_noop_without_enter_race
    HireFire::Plan.stubs(:any_allowlisted_job_queue_library_loaded?).returns(false)
    dispatcher = configure_web_only
    assert dispatcher.start
    assert_nil dispatcher.instance_variable_get(:@job_queue_thread)
    dispatcher.ensure_job_queue_loop
    assert_nil dispatcher.instance_variable_get(:@job_queue_thread)
    dispatcher.stop
  end

  def test_ensure_job_queue_loop_starts_when_enter_race_becomes_true
    HireFire::Plan.stubs(:any_allowlisted_job_queue_library_loaded?).returns(false)
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
    stub_lease

    dispatcher = configure_web_only
    assert dispatcher.start
    assert_nil dispatcher.instance_variable_get(:@job_queue_thread)

    HireFire.configuration.dyno(:worker) { 1 }
    dispatcher.ensure_job_queue_loop
    assert dispatcher.instance_variable_get(:@job_queue_thread)&.alive?
    dispatcher.stop
  end

  def test_ensure_job_queue_loop_logs_when_thread_spawn_fails
    stub_lease
    dispatcher = configure_workers_only
    dispatcher.instance_variable_set(:@running, true)
    dispatcher.instance_variable_set(:@pid, Process.pid)
    dispatcher.instance_variable_set(:@generation, 1)

    Thread.stubs(:new).raises(ThreadError.new("cannot create thread"))
    dispatcher.ensure_job_queue_loop
    assert_includes log.string, "Could not start job-queue loop"
  end

  def test_ensure_job_queue_loop_restarts_dead_job_queue_thread
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    dispatcher = configure_workers_only
    dead = Thread.new {}
    dead.join
    refute dead.alive?

    # Mark running without spawning loops so ensure_job_queue_loop is the only starter.
    dispatcher.instance_variable_set(:@running, true)
    dispatcher.instance_variable_set(:@pid, Process.pid)
    dispatcher.instance_variable_set(:@generation, 1)
    dispatcher.instance_variable_set(:@job_queue_thread, dead)

    dispatcher.ensure_job_queue_loop
    restarted = dispatcher.instance_variable_get(:@job_queue_thread)
    refute_same dead, restarted
    assert restarted.alive?

    dispatcher.instance_variable_set(:@running, false)
    restarted.join(HireFire::Dispatcher::JOIN_TIMEOUT)
  end

  def test_start_restarts_when_main_loop_thread_is_dead
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    dispatcher = configure_web_only
    dead = Thread.new {}
    dead.join
    refute dead.alive?

    dispatcher.instance_variable_set(:@running, true)
    dispatcher.instance_variable_set(:@stopping, false)
    dispatcher.instance_variable_set(:@pid, Process.pid)
    dispatcher.instance_variable_set(:@thread, dead)
    dispatcher.instance_variable_set(:@generation, 1)

    refute dispatcher.running?
    assert dispatcher.start
    restarted = dispatcher.instance_variable_get(:@thread)
    refute_same dead, restarted
    assert restarted.alive?
    assert dispatcher.running?

    dispatcher.stop
  end

  def test_dispatch_with_stale_generation_does_not_post
    stub_lease
    ingest = stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    dispatcher = configure_web_only
    HireFire.configuration.buffer.sample("web", "rqt", 10)
    dispatcher.instance_variable_set(:@running, false)
    dispatcher.instance_variable_set(:@stopping, false)
    dispatcher.instance_variable_set(:@pid, Process.pid)
    dispatcher.instance_variable_set(:@generation, 2)

    # Generation 1 is stale at entry: no flush, no POST (samples stay buffered).
    dispatcher.send(:dispatch, 1)

    assert_not_requested ingest
    data = HireFire.configuration.buffer.flush
    assert data.dig("web", "rqt")
  end

  def test_dispatch_dead_gen_after_flush_does_not_repopulate_when_not_final_flush
    stub_lease
    ingest = stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    dispatcher = configure_web_only
    HireFire.configuration.buffer.sample("web", "rqt", 10)
    dispatcher.instance_variable_set(:@running, true)
    dispatcher.instance_variable_set(:@stopping, false)
    dispatcher.instance_variable_set(:@stopping_flush, false)
    dispatcher.instance_variable_set(:@pid, Process.pid)
    dispatcher.instance_variable_set(:@generation, 1)

    # After flush, generation dies (stop(flush: false) path). Must not POST and must not
    # repopulate (would undo discard).
    calls = 0
    dispatcher.define_singleton_method(:loop_active?) do |generation|
      calls += 1
      calls == 1
    end

    dispatcher.send(:dispatch, 1)

    assert_not_requested ingest
    assert_empty HireFire.configuration.buffer.flush
  end

  def test_dispatch_dead_gen_after_flush_handoffs_for_final_flush
    stub_lease
    ingest = stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    dispatcher = configure_web_only
    HireFire.configuration.buffer.sample("web", "rqt", 10)
    dispatcher.instance_variable_set(:@running, false)
    dispatcher.instance_variable_set(:@stopping, true)
    dispatcher.instance_variable_set(:@stopping_flush, true)
    dispatcher.instance_variable_set(:@pid, Process.pid)
    dispatcher.instance_variable_set(:@generation, 1)

    calls = 0
    dispatcher.define_singleton_method(:loop_active?) do |_generation|
      calls += 1
      calls == 1
    end

    dispatcher.send(:dispatch, 1)

    assert_not_requested ingest
    data = HireFire.configuration.buffer.flush
    assert data.dig("web", "rqt")
  end

  def test_abandon_inherited_state_clears_running_and_buffer
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    dispatcher = configure_web_only
    assert dispatcher.start
    HireFire.configuration.buffer.sample("web", "rqt", 7)

    dispatcher.abandon_inherited_state!

    refute dispatcher.running?
    assert_empty HireFire.configuration.buffer.flush
  end

  def test_abandon_inherited_state_demotes_and_closes_transports
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    dispatcher = configure_web_only
    assert dispatcher.start
    dispatcher.instance_variable_get(:@client).expects(:close).at_least_once
    dispatcher.instance_variable_get(:@lease).expects(:demote!).at_least_once
    dispatcher.instance_variable_get(:@lease).expects(:close).at_least_once

    dispatcher.abandon_inherited_state!
  end

  def test_stop_after_abandon_does_not_post_buffered_samples
    stub_lease
    ingest = stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    dispatcher = configure_web_only
    assert dispatcher.start
    HireFire.configuration.buffer.sample("web", "rqt", 7)
    dispatcher.abandon_inherited_state!
    WebMock.reset_executed_requests!

    refute dispatcher.stop
    assert_not_requested ingest
    assert_empty HireFire.configuration.buffer.flush
  end

  def test_dispatch_dead_gen_after_successful_post_skips_watermark_and_frequency
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .to_return(status: 200, headers: {"HireFire-Dispatch-Frequency" => "10"})

    dispatcher = configure_web_only
    HireFire.configuration.buffer.sample("web", "rqt", 10)
    dispatcher.instance_variable_set(:@running, true)
    dispatcher.instance_variable_set(:@stopping, false)
    dispatcher.instance_variable_set(:@stopping_flush, false)
    dispatcher.instance_variable_set(:@pid, Process.pid)
    dispatcher.instance_variable_set(:@generation, 1)
    dispatcher.instance_variable_set(:@last_rqt_second, 999)
    dispatcher.instance_variable_set(:@dispatch_frequency, 1)

    calls = 0
    dispatcher.define_singleton_method(:loop_active?) do |_generation|
      calls += 1
      # Active through build/POST; dead for post-response apply.
      calls <= 2
    end

    dispatcher.send(:dispatch, 1)

    assert_equal 999, dispatcher.instance_variable_get(:@last_rqt_second)
    assert_equal 1, dispatcher.instance_variable_get(:@dispatch_frequency)
  end

  def test_dispatch_dead_gen_on_error_does_not_repopulate_without_handoff
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_raise(Errno::ECONNREFUSED)

    dispatcher = configure_web_only
    HireFire.configuration.buffer.sample("web", "rqt", 10)
    dispatcher.instance_variable_set(:@running, true)
    dispatcher.instance_variable_set(:@stopping, false)
    dispatcher.instance_variable_set(:@stopping_flush, false)
    dispatcher.instance_variable_set(:@pid, Process.pid)
    dispatcher.instance_variable_set(:@generation, 1)

    calls = 0
    dispatcher.define_singleton_method(:loop_active?) do |_generation|
      calls += 1
      # Active for flush/build; dead for rescue repopulate check.
      calls <= 2
    end

    dispatcher.send(:dispatch, 1)

    assert_empty HireFire.configuration.buffer.flush
  end

  def test_dispatch_dead_gen_on_error_handoffs_for_final_flush
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_raise(Errno::ECONNREFUSED)

    dispatcher = configure_web_only
    HireFire.configuration.buffer.sample("web", "rqt", 10)
    dispatcher.instance_variable_set(:@running, false)
    dispatcher.instance_variable_set(:@stopping, true)
    dispatcher.instance_variable_set(:@stopping_flush, true)
    dispatcher.instance_variable_set(:@pid, Process.pid)
    dispatcher.instance_variable_set(:@generation, 1)

    calls = 0
    dispatcher.define_singleton_method(:loop_active?) do |_generation|
      calls += 1
      calls <= 2
    end

    dispatcher.send(:dispatch, 1)

    data = HireFire.configuration.buffer.flush
    assert data.dig("web", "rqt")
  end

  def test_dispatch_if_due_does_not_advance_pacing_on_dead_gen
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    dispatcher = configure_web_only
    HireFire.configuration.buffer.sample("web", "rqt", 10)
    dispatcher.instance_variable_set(:@running, true)
    dispatcher.instance_variable_set(:@stopping, false)
    dispatcher.instance_variable_set(:@stopping_flush, false)
    dispatcher.instance_variable_set(:@pid, Process.pid)
    dispatcher.instance_variable_set(:@generation, 1)
    dispatcher.instance_variable_set(:@next_dispatch_at, nil)

    calls = 0
    dispatcher.define_singleton_method(:loop_active?) do |_generation|
      calls += 1
      # First check in dispatch_if_due and early dispatch pass; later checks fail.
      calls == 1
    end

    dispatcher.send(:dispatch_if_due, 1)

    assert_nil dispatcher.instance_variable_get(:@next_dispatch_at)
  end

  def test_stop_closes_transports_even_when_final_dispatch_raises
    stub_lease
    dispatcher = configure_web_only
    dispatcher.instance_variable_set(:@running, true)
    dispatcher.instance_variable_set(:@pid, Process.pid)
    dispatcher.define_singleton_method(:dispatch) { raise "flush failed" }

    dispatcher.instance_variable_get(:@client).expects(:close).at_least_once
    dispatcher.instance_variable_get(:@lease).expects(:demote!).at_least_once
    dispatcher.instance_variable_get(:@lease).expects(:close).at_least_once

    assert_raises(RuntimeError) { dispatcher.stop }

    refute dispatcher.instance_variable_get(:@stopping)
  end

  def test_forked_child_start_reinitializes_buffer_mutex
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    dispatcher = configure_web_only
    assert dispatcher.start
    buffer = HireFire.configuration.buffer
    old_mutex = buffer.instance_variable_get(:@mutex)

    child_pid = Process.pid + 1
    Process.stubs(:pid).returns(child_pid)
    assert dispatcher.start

    refute_same old_mutex, buffer.instance_variable_get(:@mutex)
    assert_empty buffer.flush
    dispatcher.stop
  end

  def test_stop_without_flush_discards_buffer
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    dispatcher = configure_web_only
    assert dispatcher.start
    HireFire.configuration.buffer.sample("web", "rqt", 42)
    dispatcher.stop(flush: false)

    assert_empty HireFire.configuration.buffer.flush
  end

  def test_fork_resets_always_on_cpu_and_warn_maps
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    ENV["DYNO"] = "web.1"
    dispatcher = configure_web_only
    first_cpu = HireFire.configuration.active_cpu_sources.first
    assert first_cpu

    dispatcher.instance_variable_set(:@unloaded_adapter_warned, {"worker" => true})
    dispatcher.instance_variable_set(:@plan_override_warned, {"worker" => true})
    dispatcher.instance_variable_set(:@unknown_adapter_warned, {"worker" => true})
    dispatcher.instance_variable_set(:@unsupported_strategy_warned, {"worker\0bunny\0jql" => true})
    assert dispatcher.start

    child_pid = dispatcher.instance_variable_get(:@pid) + 1
    Process.stubs(:pid).returns(child_pid)
    assert dispatcher.start

    second_cpu = HireFire.configuration.active_cpu_sources.first
    refute_same first_cpu, second_cpu
    assert_empty dispatcher.instance_variable_get(:@unloaded_adapter_warned)
    assert_empty dispatcher.instance_variable_get(:@plan_override_warned)
    assert_empty dispatcher.instance_variable_get(:@unknown_adapter_warned)
    assert_empty dispatcher.instance_variable_get(:@unsupported_strategy_warned)

    dispatcher.stop
  end

  def test_wire_payload_nested_multi_strategy_shape
    stub_lease(granted: true)
    bodies = capture_ingest_bodies

    Timecop.freeze Time.at(1000) do
      ENV["DYNO"] = "web.1"
      HireFire.configuration.dyno(:web)
      HireFire.configuration.dyno(:worker) { 3 }
      dispatcher = HireFire.configuration.dispatcher

      HireFire.configuration.buffer.sample("web", "rqt", 12)
      HireFire.configuration.buffer.sample("web", "cpu", 25.0)
      dispatcher.send(:job_queue_tick)
      dispatcher.send(:tick)
    end

    assert_operator bodies.size, :>=, 1
    payload = bodies[0]
    web = payload.find { |e| e["name"] == "web" }
    worker = payload.find { |e| e["name"] == "worker" }

    refute_nil web
    refute_nil worker
    assert_equal({"1000" => [12.0, 1]}, web.dig("metrics", "rqt"))
    assert_equal({"1000" => 25.0}, web.dig("metrics", "cpu"))
    assert worker.dig("metrics", "jql")
    assert(payload.all? { |e| e.keys.sort == %w[metrics name] })
    assert(payload.all? { |e| e["metrics"].keys.all? { |k| k.is_a?(String) } })
  end

  def test_vector_c_encode_rqt_mean_and_count
    stub_lease
    bodies = capture_ingest_bodies
    dispatcher = configure_web_only

    Timecop.freeze Time.at(1000) do
      HireFire.configuration.buffer.sample("web", "rqt", 10)
      HireFire.configuration.buffer.sample("web", "rqt", 20)
      HireFire.configuration.buffer.sample("web", "rqt", 30)
      dispatcher.send(:tick)
    end

    assert_equal [20.0, 3], bodies[0][0].dig("metrics", "rqt", "1000")
  end

  def test_payload_size_limit_is_32768_with_strict_greater_drop
    limit = HireFire::Dispatcher::PAYLOAD_SIZE_LIMIT
    assert_equal 32_768, limit

    stub_lease
    ingest = stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
    dispatcher = configure_web_only

    # Equality is accepted: body of exactly PAYLOAD_SIZE_LIMIT still POSTs.
    Timecop.freeze Time.at(1000) do
      HireFire.configuration.buffer.sample("web", "rqt", 1)
      JSON.stubs(:generate).returns("e" * limit)
      dispatcher.send(:tick)
    end
    assert_requested ingest, times: 1
    refute_includes log.string, "Dropped metrics payload"

    # Strict greater drops without a request and logs the oversize path.
    Timecop.freeze Time.at(1001) do
      HireFire.configuration.buffer.sample("web", "rqt", 1)
      JSON.stubs(:generate).returns("o" * (limit + 1))
      dispatcher.send(:tick)
    end
    assert_requested ingest, times: 1
    assert_includes log.string, "Dropped metrics payload"
    assert_includes log.string, "#{limit + 1} bytes"
    assert_includes log.string, "exceeds the #{limit}-byte limit"
  ensure
    JSON.unstub(:generate)
  end

  def test_encode_omits_non_finite_rqt_mean
    stub_lease
    bodies = capture_ingest_bodies
    dispatcher = configure_web_only

    Timecop.freeze Time.at(1000) do
      buffer = HireFire.configuration.buffer
      buffer.instance_variable_get(:@mutex).synchronize do
        metrics = buffer.instance_variable_get(:@metrics)
        # Mix finite and non-finite so a POST still happens (liveness + real leaf).
        metrics["web"] = {
          "rqt" => {
            1000 => {sum: Float::INFINITY, count: 1},
            999 => {sum: 10.0, count: 1}
          }
        }
      end
      dispatcher.send(:tick)
    end

    assert_operator bodies.size, :>=, 1
    rqt = bodies[0][0].dig("metrics", "rqt")
    refute rqt.key?("1000")
    assert_equal [10.0, 1], rqt["999"]
    assert_includes log.string, "Omitting rqt second"
  end

  def test_encode_omits_invalid_non_rqt_values
    stub_lease(granted: true)
    bodies = capture_ingest_bodies
    limit = HireFire::Dispatcher::METRIC_VALUE_LIMIT

    Timecop.freeze Time.at(1000) do
      ENV["DYNO"] = "web.1"
      HireFire.configuration.dyno(:web)
      HireFire.configuration.dyno(:worker) { 1 }
      dispatcher = HireFire.configuration.dispatcher

      buffer = HireFire.configuration.buffer
      buffer.instance_variable_get(:@mutex).synchronize do
        metrics = buffer.instance_variable_get(:@metrics)
        metrics["worker"] = {
          "jql" => {
            1000 => Float::NAN,
            999 => Float::INFINITY,
            998 => -1.0,
            997 => limit + 1,
            996 => "nope",
            995 => 4.5
          },
          "cpu" => {
            1000 => -0.1,
            999 => 12.0
          }
        }
        metrics["web"] = {
          "rqt" => {1000 => {sum: 1.0, count: 1}}
        }
      end
      dispatcher.send(:tick)
    end

    assert_operator bodies.size, :>=, 1
    worker = bodies[0].find { |e| e["name"] == "worker" }
    refute_nil worker
    jql = worker.dig("metrics", "jql") || {}
    cpu = worker.dig("metrics", "cpu") || {}
    refute jql.key?("1000")
    refute jql.key?("999")
    refute jql.key?("998")
    refute jql.key?("997")
    refute jql.key?("996")
    assert_equal 4.5, jql["995"]
    refute cpu.key?("1000")
    assert_equal 12.0, cpu["999"]
  end

  def test_encode_clamps_rqt_sample_count_to_limit
    stub_lease
    bodies = capture_ingest_bodies
    dispatcher = configure_web_only
    limit = HireFire::Dispatcher::SAMPLE_COUNT_LIMIT

    Timecop.freeze Time.at(1000) do
      buffer = HireFire.configuration.buffer
      buffer.instance_variable_get(:@mutex).synchronize do
        metrics = buffer.instance_variable_get(:@metrics)
        metrics["web"] = {
          "rqt" => {
            1000 => {sum: 20.0 * (limit + 50), count: limit + 50}
          }
        }
      end
      dispatcher.send(:tick)
    end

    assert_equal [20.0, limit], bodies[0][0].dig("metrics", "rqt", "1000")
  end

  def test_hold_lease_true_when_only_supported_plan_entries_without_local_dynos
    HireFire::Plan.stubs(:executable?).with("sidekiq").returns(true)
    HireFire::Plan.stubs(:supports_strategy?).with("sidekiq", "jql").returns(true)

    dispatcher = HireFire.configuration.dispatcher
    refute HireFire.configuration.job_queues.any?

    plan = [
      {"name" => "worker", "strategy" => "jql", "adapter" => "sidekiq", "queues" => ["default"], "options" => {}}
    ]
    assert dispatcher.send(:hold_lease?, plan)
  end

  def test_partial_plan_unsupported_jql_and_supported_jqs_holds_and_samples_size
    size_calls = 0
    latency_calls = 0
    mod = Module.new
    mod.extend(HireFire::Plan::Hooks)
    mod.extend(HireFire::Errors::JobQueueLatencyUnsupported)
    mod.define_singleton_method(:job_queue_size) { |*_queues, **_options|
      size_calls += 1
      9
    }
    mod.define_singleton_method(:job_queue_latency) do |*_queues, **_options|
      latency_calls += 1
      raise "jql must not run"
    end

    original = HireFire::Plan::ADAPTERS
    original_checks = HireFire::Plan::LIBRARY_CHECKS
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original.merge("bunny" => mod))
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks.merge("bunny" => -> { true }))
    HireFire::Plan.stubs(:any_allowlisted_job_queue_library_loaded?).returns(true)

    stub_lease(granted: true, job_queues: [
      {"name" => "worker", "strategy" => "jql", "adapter" => "bunny", "queues" => ["default"], "options" => {}},
      {"name" => "worker", "strategy" => "jqs", "adapter" => "bunny", "queues" => ["default"], "options" => {}}
    ])
    bodies = capture_ingest_bodies

    dispatcher = HireFire.configuration.dispatcher
    dispatcher.send(:job_queue_tick)
    assert dispatcher.instance_variable_get(:@lease).granted?
    dispatcher.send(:tick)

    assert_equal 0, latency_calls
    assert_equal 1, size_calls
    entry = bodies[0].find { |e| e["name"] == "worker" }
    assert_equal 9, entry.dig("metrics", "jqs").values.first
    refute entry.dig("metrics", "jql")
    assert_includes log.string, "does not support"
  ensure
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original)
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks)
  end

  def test_unsupported_strategy_once_log_is_isolated_per_name_adapter_strategy
    mod = Module.new
    mod.extend(HireFire::Plan::Hooks)
    mod.extend(HireFire::Errors::JobQueueLatencyUnsupported)
    mod.define_singleton_method(:job_queue_size) { |*_queues, **_options| 1 }

    original = HireFire::Plan::ADAPTERS
    original_checks = HireFire::Plan::LIBRARY_CHECKS
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original.merge("bunny" => mod, "resque" => mod))
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks.merge(
      "bunny" => -> { true },
      "resque" => -> { true }
    ))

    stub_lease(granted: true, job_queues: [
      {"name" => "worker", "strategy" => "jql", "adapter" => "bunny", "queues" => [], "options" => {}},
      {"name" => "mailer", "strategy" => "jql", "adapter" => "bunny", "queues" => [], "options" => {}},
      {"name" => "worker", "strategy" => "jql", "adapter" => "resque", "queues" => [], "options" => {}}
    ])

    HireFire.configuration.dyno(:other) { 0 }
    dispatcher = HireFire.configuration.dispatcher
    dispatcher.send(:job_queue_tick)
    dispatcher.send(:job_queue_tick)

    assert_equal 3, log.string.scan("does not support").size
    warned = dispatcher.instance_variable_get(:@unsupported_strategy_warned)
    assert warned["worker\0bunny\0jql"]
    assert warned["mailer\0bunny\0jql"]
    assert warned["worker\0resque\0jql"]
  ensure
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original)
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks)
  end

  def test_413_advances_watermark_without_repopulate
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .to_return(status: 413, body: '{"error":"payload too large"}')

    dispatcher = configure_web_only
    Timecop.freeze Time.at(1000) do
      HireFire.configuration.buffer.sample("web", "rqt", 7)
      dispatcher.send(:tick)
    end

    data = HireFire.configuration.buffer.flush
    assert_nil data.dig("web", "rqt")
    assert_equal 1000, dispatcher.instance_variable_get(:@last_rqt_second)
    assert_includes log.string, "Dropped metrics payload"
  end

  private

  # Inject enough process/second series that JSON exceeds PAYLOAD_SIZE_LIMIT.
  def inject_oversized_series(name, strategy)
    buffer = HireFire.configuration.buffer
    now = Time.now.to_i
    bucket = (strategy == "rqt") ? {sum: 1.0, count: 1} : 1.0
    buffer.instance_variable_get(:@mutex).synchronize do
      metrics = buffer.instance_variable_get(:@metrics)
      400.times do |i|
        process_name = "p#{i}-#{"x" * 48}"
        series = {}
        60.times { |s| series[now - s] = (strategy == "rqt") ? {sum: 1.0, count: 1} : 1.0 }
        metrics[process_name] = {strategy => series}
      end
      metrics[name] ||= {}
      metrics[name][strategy] = {now => bucket}
    end
  end
end
