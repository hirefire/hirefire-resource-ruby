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

  def session
    @session ||= HireFire::Dispatcher::Session.new(HireFire.configuration)
  end

  def job_queue_pass
    session.renew
    session.sample
  end

  def stub_lease(granted: false, job_queues: nil, trace: false)
    body = if job_queues.nil?
      if granted
        payload = {version: 1, job_queues: [
          {"name" => "worker", "strategy" => "jql", "adapter" => nil, "queues" => [], "options" => {}},
          {"name" => "mailer", "strategy" => "jql", "adapter" => nil, "queues" => [], "options" => {}}
        ]}
        payload[:trace] = true if trace
        payload.to_json
      else
        ""
      end
    else
      payload = {version: 1, job_queues: job_queues}
      payload[:trace] = true if trace
      payload.to_json
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

    configure_web_only

    Timecop.freeze Time.at(1000) do
      HireFire.configuration.buffer.sample("web", "rqt", 12)
      HireFire.configuration.buffer.sample("web", "rqt", 8)
      session.report
    end

    assert_requested request
  end

  def test_dispatches_jqs_and_wrk_as_sibling_bare_numbers
    stub_lease
    bodies = capture_ingest_bodies
    configure_workers_only

    Timecop.freeze Time.at(2500) do
      HireFire.configuration.buffer.sample("worker", "jqs", 12)
      HireFire.configuration.buffer.sample("worker", "wrk", 3)
      session.flush
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

    configure_web_only

    Timecop.freeze Time.at(1000) do
      HireFire.configuration.buffer.sample("web", "rqt", 12)
      session.report
    end

    assert_includes log.string, "Dispatching metrics"
  end

  def test_no_dispatch_when_nothing_configured
    stub_lease
    HireFire.configuration.dispatcher
    session.report

    assert_not_requested(:post, "https://data.hirefire.io/metrics/ingest")
  end

  def test_first_dispatch_claims_only_the_current_second
    stub_lease
    bodies = capture_ingest_bodies

    configure_web_only
    Timecop.freeze(Time.at(1000)) { session.report }

    assert_equal({"1000" => []}, bodies[0][0].dig("metrics", "rqt"))
  end

  def test_backfills_seconds_skipped_between_dispatches
    stub_lease
    bodies = capture_ingest_bodies

    configure_web_only
    Timecop.freeze(Time.at(1000)) { session.report }
    Timecop.freeze(Time.at(1003)) { session.report }

    assert_equal({"1001" => [], "1002" => [], "1003" => []}, bodies[1][0].dig("metrics", "rqt"))
  end

  def test_backfill_preserves_buffered_samples
    stub_lease
    bodies = capture_ingest_bodies

    configure_web_only
    Timecop.freeze(Time.at(1000)) { session.report }
    Timecop.freeze(Time.at(1003)) do
      HireFire.configuration.buffer.sample("web", "rqt", 5)
      session.report
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

    configure_web_only
    Timecop.freeze(Time.at(1000)) { session.report }
    Timecop.freeze(Time.at(1003)) { session.report }
    Timecop.freeze(Time.at(1005)) { session.report }

    assert_equal %w[1001 1002 1003 1004 1005], bodies[2][0].dig("metrics", "rqt").keys.sort
  end

  def test_backfill_is_capped_at_the_limit
    stub_lease
    bodies = capture_ingest_bodies

    configure_web_only
    Timecop.freeze(Time.at(1000)) { session.report }
    Timecop.freeze(Time.at(1000 + 100)) { session.report }

    keys = bodies[1][0].dig("metrics", "rqt").keys.map(&:to_i)
    assert_equal 1100 - HireFire::Dispatcher::RQT_BACKFILL_LIMIT, keys.min
    assert_equal 1100, keys.max
    assert_equal HireFire::Dispatcher::RQT_BACKFILL_LIMIT + 1, keys.size
  end

  def test_lease_unauthorized_does_not_log_error
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 401)

    configure_workers_only
    job_queue_pass
    session.report

    assert_not_requested(:post, "https://data.hirefire.io/metrics/ingest")
    refute_match(/\b401\b/, log.string)
  end

  def test_web_buffer_discarded_on_unauthorized
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .to_return(status: 401)

    configure_web_only

    Timecop.freeze Time.at(1000) do
      HireFire.configuration.buffer.sample("web", "rqt", 7)
      session.report
    end

    data = HireFire.configuration.buffer.flush
    assert_nil data.dig("web", "rqt")
    assert_equal %w[1001 1002], seconds_claimed_at(1002)
    refute_includes log.string, "Dispatch error"
  end

  def test_web_buffer_repopulated_on_dispatch_failure
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .to_return(status: 500)

    configure_web_only

    Timecop.freeze Time.at(1000) do
      HireFire.configuration.buffer.sample("web", "rqt", 7)
      session.report
    end

    data = HireFire.configuration.buffer.flush
    assert_equal({sum: 7.0, count: 1}, data.dig("web", "rqt", 1000))
  end

  def test_oversized_payload_is_dropped_without_a_request
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    configure_web_only

    Timecop.freeze Time.at(1000) do
      inject_oversized_series("web", "rqt")
      session.report
    end

    assert_not_requested(:post, "https://data.hirefire.io/metrics/ingest")
    assert_nil HireFire.configuration.buffer.flush.dig("web", "rqt")
    assert_includes log.string, "Dropped metrics payload"
  end

  def test_oversized_drop_advances_the_watermark_past_the_hole
    stub_lease
    bodies = capture_ingest_bodies

    configure_web_only
    Timecop.freeze(Time.at(1000)) { session.report }
    Timecop.freeze Time.at(1010) do
      inject_oversized_series("web", "rqt")
      session.report
    end
    Timecop.freeze(Time.at(1012)) { session.report }

    assert_equal 2, bodies.size
    assert_equal %w[1011 1012], bodies[1][0].dig("metrics", "rqt").keys.sort
  end

  def test_an_oversized_payload_without_web_data_drops_without_touching_the_watermark
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    HireFire.configuration.dispatcher

    Timecop.freeze Time.at(1000) do
      inject_oversized_series("worker", "jql")
      session.report
    end

    assert_not_requested(:post, "https://data.hirefire.io/metrics/ingest")
    assert_includes log.string, "Dropped metrics payload"
  end

  def test_dispatch_tick_does_not_run_job_queue_sampling
    stub_lease(granted: true)
    bodies = capture_ingest_bodies
    sampled = false

    Timecop.freeze Time.at(1000) do
      HireFire.configuration.dyno(:web)
      HireFire.configuration.dyno(:worker) { sampled = true }
      HireFire.configuration.dispatcher
      HireFire.configuration.buffer.sample("web", "rqt", 5)

      session.report
    end

    assert_equal ["web"], bodies[0].map { |e| e["name"] }
    refute sampled
  end

  def test_job_queue_tick_samples_without_dispatching_and_a_later_tick_delivers_it
    stub_lease(granted: true)
    bodies = capture_ingest_bodies

    Timecop.freeze Time.at(1000) do
      HireFire.configuration.dyno(:worker) { 42 }
      HireFire.configuration.dispatcher

      job_queue_pass
      assert_empty bodies

      session.report
    end

    assert_equal 1, bodies.size
    assert(bodies[0].any? { |e| e["name"] == "worker" && e.dig("metrics", "jql", "1000") == 42 })
  end

  def test_hyphen_dyno_samples_and_dispatches_name_as_is
    stub_lease(granted: true, job_queues: [
      {"name" => "worker-latency", "strategy" => "jql", "adapter" => nil, "queues" => [], "options" => {}}
    ])
    bodies = capture_ingest_bodies
    ENV["DYNO"] = "worker-latency-6d7f788ddb-cdct6"

    Timecop.freeze Time.at(1000) do
      HireFire.configuration.dyno("worker-latency") { 7 }
      HireFire.configuration.dyno(:"worker-size") { 3 }
      HireFire.configuration.dispatcher
      job_queue_pass
      session.report
    end

    names = bodies.fetch(0).map { |e| e["name"] }
    assert_includes names, "worker-latency"
    refute_includes names, "worker"
    entry = bodies[0].find { |e| e["name"] == "worker-latency" }
    assert_equal 7, entry.dig("metrics", "jql", "1000")
    refute_includes log.string, "local sampler is ignored"
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
      configure_web_and_workers
      HireFire.configuration.buffer.sample("web", "rqt", 5)
      job_queue_pass
      session.report
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

    configure_workers_only
    job_queue_pass
    session.report

    assert_requested ingest
  end

  def test_sample_trace_attached_when_grant_trace_true
    stub_lease(granted: true, trace: true)
    bodies = capture_ingest_bodies

    configure_workers_only
    job_queue_pass
    session.report

    assert_equal 1, bodies.size
    assert bodies[0].first.key?("sample_trace"), "sample_trace attaches to first process report"
    entry = bodies[0].first
    assert entry["sample_trace"].key?("wave_ms")
    assert entry["sample_trace"]["ops"].is_a?(Array)
    assert_equal 2, entry["sample_trace"]["ops"].size, "one op per plan job_queue entry"
    assert entry["sample_trace"]["ops"].all? { |op| op["strategy"] == "jql" && op.key?("ms") }
    bodies[0].drop(1).each { |e| refute e.key?("sample_trace") }
  end

  def test_oversized_sample_trace_is_stripped_so_metrics_still_ship
    stub_lease(granted: true, trace: true, job_queues: [
      {"name" => "worker", "strategy" => "jql", "queues" => ["q" * 130_800]}
    ])
    bodies = capture_ingest_bodies
    configure_web_and_workers

    Timecop.freeze(Time.at(1000)) { session.report }
    Timecop.freeze Time.at(1050) do
      HireFire.configuration.buffer.sample("web", "rqt", 7)
      job_queue_pass
      session.report
    end

    assert_equal 2, bodies.size
    assert_equal %w[web worker], bodies[1].map { |entry| entry["name"] }
    refute bodies[1].first.key?("sample_trace")
    assert_equal [7.0, 1], bodies[1].first.dig("metrics", "rqt", "1050")
    refute_includes log.string, "Dropped metrics payload"
  end

  def test_sample_trace_absent_without_grant_trace
    stub_lease(granted: true, trace: false)
    bodies = capture_ingest_bodies

    configure_workers_only
    job_queue_pass
    session.report

    assert bodies.any?
    bodies[0].each { |e| refute e.key?("sample_trace") }
  end

  def test_verbose_logs_sample_timings_without_server_trace
    ENV["HIREFIRE_VERBOSE"] = "1"
    stub_lease(granted: true, trace: false)

    configure_workers_only
    job_queue_pass

    assert_includes log.string, "sample_job_queues wave_ms="
    assert_includes log.string, "sample adapter="
  ensure
    ENV.delete("HIREFIRE_VERBOSE")
  end

  def test_lease_denied_skips_worker_collection
    stub_lease

    configure_workers_only
    job_queue_pass
    session.report

    assert_not_requested(:post, "https://data.hirefire.io/metrics/ingest")
  end

  def test_dispatches_cpu_samples_in_the_nested_format
    HireFire::Source::CPU::Usage.stubs(:available_cpus).returns(1.0)
    HireFire::Source::CPU::Usage.stubs(:reading).returns([0.0, :cgroup_v2], [0.5, :cgroup_v2])
    bodies = capture_ingest_bodies

    configure_cpu_only("clock")
    Timecop.freeze(Time.at(1000)) { session.report }
    Timecop.freeze(Time.at(1001)) { session.report }

    assert_equal 1, bodies.size
    entry = bodies[0][0]
    assert_equal "clock", entry["name"]
    assert_equal({"1001" => 50.0}, entry.dig("metrics", "cpu"))
  end

  def test_cpu_first_tick_seeds_baseline_without_dispatching
    HireFire::Source::CPU::Usage.stubs(:available_cpus).returns(1.0)
    HireFire::Source::CPU::Usage.stubs(:reading).returns([0.0, :cgroup_v2])
    bodies = capture_ingest_bodies

    configure_cpu_only("clock")
    Timecop.freeze(Time.at(1000)) { session.report }

    assert_empty bodies
  end

  def test_cpu_samples_are_not_repopulated_on_dispatch_failure
    HireFire::Source::CPU::Usage.stubs(:available_cpus).returns(1.0)
    HireFire::Source::CPU::Usage.stubs(:reading).returns([0.0, :cgroup_v2], [0.5, :cgroup_v2])
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 500)

    configure_cpu_only("clock")
    Timecop.freeze(Time.at(1000)) { session.report }
    Timecop.freeze(Time.at(1001)) { session.report }

    data = HireFire.configuration.buffer.flush
    assert_nil data.dig("clock", "cpu")
  end

  def test_non_web_process_does_not_heartbeat_the_web_name
    stub_lease
    ENV["DYNO"] = "worker.1"
    HireFire.configuration.dyno(:web)
    HireFire.configuration.dispatcher

    session.report

    assert_not_requested(:post, "https://data.hirefire.io/metrics/ingest")
  end

  def test_non_web_process_still_delivers_real_web_samples
    stub_lease
    ENV["DYNO"] = "worker.1"
    HireFire.configuration.dyno(:web)
    HireFire.configuration.dispatcher
    bodies = capture_ingest_bodies

    Timecop.freeze(Time.at(1000)) do
      HireFire.configuration.buffer.sample("web", "rqt", 12)
      session.report
    end

    assert_equal({"1000" => [12.0, 1]}, bodies[0][0].dig("metrics", "rqt"))
  end

  def test_matching_identity_keeps_heartbeat_and_backfill
    stub_lease
    ENV["DYNO"] = "web.1"
    HireFire.configuration.dyno(:web)
    HireFire.configuration.dispatcher
    bodies = capture_ingest_bodies

    Timecop.freeze(Time.at(1000)) { session.report }
    Timecop.freeze(Time.at(1002)) { session.report }

    assert_equal({"1000" => []}, bodies[0][0].dig("metrics", "rqt"))
    assert_equal({"1001" => [], "1002" => []}, bodies[1][0].dig("metrics", "rqt"))
  end

  def test_unresolved_identity_does_not_synthesize_liveness
    stub_lease
    HireFire.configuration.dyno(:web)
    HireFire.configuration.dispatcher
    bodies = capture_ingest_bodies

    Timecop.freeze(Time.at(1000)) { session.report }

    assert_empty bodies
  end

  def test_always_on_cpu_uses_identity_name_through_the_tick
    HireFire::Source::CPU::Usage.stubs(:available_cpus).returns(1.0)
    HireFire::Source::CPU::Usage.stubs(:reading).returns([0.0, :cgroup_v2], [0.5, :cgroup_v2])
    stub_lease
    bodies = capture_ingest_bodies

    ENV["HIREFIRE_SERVICE_NAME"] = "web"
    HireFire.configuration.dispatcher

    Timecop.freeze(Time.at(1000)) { session.report }
    Timecop.freeze(Time.at(1001)) { session.report }

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

  def test_tick_dispatches_when_a_sampler_raises
    stub_lease(granted: true)
    bodies = capture_ingest_bodies

    Timecop.freeze Time.at(1000) do
      ENV["DYNO"] = "web.1"
      HireFire.configuration.dyno(:web)
      HireFire.configuration.dyno(:worker) { raise "Redis down" }
      HireFire.configuration.dispatcher
      job_queue_pass
      session.report
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
    dispatcher.stop
  end

  def test_web_only_dispatch_never_requests_a_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    configure_web_only
    Timecop.freeze(Time.at(1000)) { session.report }

    assert_not_requested(:post, "https://data.hirefire.io/metrics/lease")
  end

  def stub_ingest_with_dispatch_frequency(value)
    stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .to_return(status: 200, headers: {"HireFire-Dispatch-Frequency" => value.to_s})
  end

  def test_dispatch_frequency_defaults_to_one_without_the_header
    stub_lease
    bodies = capture_ingest_bodies

    configure_web_only
    Timecop.freeze(Time.at(1000)) { session.report }
    Timecop.freeze(Time.at(1001)) { session.report }

    assert_equal 2, bodies.size
  end

  def test_honors_a_server_supplied_dispatch_frequency
    stub_lease
    stub_ingest_with_dispatch_frequency(5)

    configure_web_only
    Timecop.freeze(Time.at(1000)) { session.report }
    Timecop.freeze(Time.at(1002)) { session.report }
    Timecop.freeze(Time.at(1004)) { session.report }
    Timecop.freeze(Time.at(1005)) { session.report }

    assert_requested(:post, "https://data.hirefire.io/metrics/ingest", times: 2)
  end

  def test_clamps_an_over_large_dispatch_frequency_to_the_maximum
    stub_lease
    stub_ingest_with_dispatch_frequency(HireFire::Dispatcher::MAX_DISPATCH_FREQUENCY + 100)

    configure_web_only
    Timecop.freeze(Time.at(1000)) { session.report }

    Timecop.freeze(Time.at(1000 + HireFire::Dispatcher::MAX_DISPATCH_FREQUENCY - 1)) { session.report }
    assert_requested(:post, "https://data.hirefire.io/metrics/ingest", times: 1)
    Timecop.freeze(Time.at(1000 + HireFire::Dispatcher::MAX_DISPATCH_FREQUENCY)) { session.report }
    assert_requested(:post, "https://data.hirefire.io/metrics/ingest", times: 2)
  end

  def test_ignores_a_non_positive_dispatch_frequency
    stub_lease
    stub_ingest_with_dispatch_frequency(0)

    configure_web_only
    Timecop.freeze(Time.at(1000)) { session.report }

    Timecop.freeze(Time.at(1001)) { session.report }
    assert_requested(:post, "https://data.hirefire.io/metrics/ingest", times: 2)
  end

  def test_ignores_an_unparseable_dispatch_frequency
    stub_lease
    stub_ingest_with_dispatch_frequency("nonsense")

    configure_web_only
    Timecop.freeze(Time.at(1000)) { session.report }

    Timecop.freeze(Time.at(1001)) { session.report }
    assert_requested(:post, "https://data.hirefire.io/metrics/ingest", times: 2)
  end

  def test_dispatch_failure_without_web_data_does_not_repopulate
    stub_lease(granted: true)
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 500)

    configure_workers_only
    job_queue_pass
    session.report

    assert_nil HireFire.configuration.buffer.flush.dig("web", "rqt")
    assert_includes log.string, "Dispatch error"
  end

  def test_tick_survives_a_payload_build_error
    stub_lease
    HireFire.configuration.buffer.stubs(:flush).raises(RuntimeError.new("boom"))

    configure_web_only
    session.report

    assert_includes log.string, "Dispatch error"
  end

  def test_nested_payload_merges_rqt_and_cpu_under_one_name
    ENV["DYNO"] = "web.1"
    HireFire::Source::CPU::Usage.stubs(:available_cpus).returns(1.0)
    HireFire::Source::CPU::Usage.stubs(:reading).returns([0.0, :cgroup_v2], [0.5, :cgroup_v2])
    bodies = capture_ingest_bodies

    HireFire.configuration.dyno(:web)
    HireFire.configuration.dispatcher

    Timecop.freeze(Time.at(1000)) { session.report }
    Timecop.freeze(Time.at(1001)) do
      HireFire.configuration.buffer.sample("web", "rqt", 12)
      session.report
    end

    entry = bodies.last.find { |e| e["name"] == "web" }
    assert entry.dig("metrics", "rqt")
    assert entry.dig("metrics", "cpu")
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
    HireFire.configuration.dispatcher
    job_queue_pass
    session.report

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
    HireFire.configuration.dispatcher
    job_queue_pass
    session.report

    entry = bodies[0].find { |e| e["name"] == "worker" }
    assert_equal 7, entry.dig("metrics", "jqs").values.first
    refute_includes log.string, "UI adapter is configured"
  end

  def test_strategy_only_plan_reports_lease_name_not_local_dyno_spelling
    stub_lease(granted: true, job_queues: [
      {"name" => "worker", "strategy" => "jqs", "adapter" => nil, "queues" => [], "options" => {}}
    ])
    bodies = capture_ingest_bodies

    HireFire.configuration.dyno(:Worker) { 7 }
    HireFire.configuration.dispatcher
    job_queue_pass
    session.report

    names = bodies[0].map { |e| e["name"] }
    assert_includes names, "worker"
    refute_includes names, "Worker"
  end

  def test_unknown_plan_adapter_skips_without_local_fallback
    stub_lease(granted: true, job_queues: [
      {"name" => "worker", "strategy" => "jql", "adapter" => "nope", "queues" => [], "options" => {}}
    ])
    bodies = capture_ingest_bodies

    HireFire.configuration.dyno(:worker) { 42 }
    HireFire.configuration.dispatcher
    job_queue_pass
    session.report

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
    HireFire.configuration.dispatcher
    job_queue_pass
    job_queue_pass
    session.report

    assert_empty bodies
    assert_equal 1, log.string.scan("is not loaded in this process").size
  end

  def test_unsupported_plan_strategy_logs_once_and_skips_macro
    calls = 0
    mod = Module.new
    mod.extend(HireFire::Plan::Hooks)
    mod.extend(HireFire::Plan::SizeOnly)
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

    HireFire.configuration.dyno(:other) { 0 }
    HireFire.configuration.dispatcher
    job_queue_pass
    job_queue_pass
    session.report

    assert_equal 0, calls
    assert_equal 1, log.string.scan("does not support").size
    refute bodies.any? { |body| body.any? { |e| e["name"] == "worker" } }
  ensure
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original)
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks)
  end

  def test_concurrent_start_during_stop_is_rejected_then_retryable_even_if_a_starter_wins_after_stopping_clears
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
        start_results << dispatcher.start
      end
    end

    Timeout.timeout(5) { stop_done.pop }
    starters.each(&:join)
    results = []
    results << start_results.pop until start_results.empty?

    dispatcher.stop if dispatcher.running?
    refute dispatcher.running?
    refute_empty results
    assert dispatcher.start
    assert dispatcher.running?
    dispatcher.stop
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
    HireFire.configuration.dispatcher
    job_queue_pass
    job_queue_pass

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
    HireFire.configuration.dispatcher
    job_queue_pass
    session.report

    assert_empty bodies
    assert_includes log.string, "Unknown plan strategy"
  end

  def test_empty_string_adapter_uses_local_strategy_sampler
    stub_lease(granted: true, job_queues: [
      {"name" => "worker", "strategy" => "jqs", "adapter" => "", "queues" => [], "options" => {}}
    ])
    bodies = capture_ingest_bodies

    HireFire.configuration.dyno(:worker) { 11 }
    HireFire.configuration.dispatcher
    job_queue_pass
    session.report

    entry = bodies[0].find { |e| e["name"] == "worker" }
    assert_equal 11, entry.dig("metrics", "jqs").values.first
  end

  def test_jql_not_repopulated_on_dispatch_failure
    stub_lease(granted: true)
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 500)

    Timecop.freeze Time.at(1000) do
      HireFire.configuration.dyno(:worker) { 3 }
      HireFire.configuration.dispatcher
      job_queue_pass
      session.report

      assert_empty HireFire.configuration.buffer.flush
      assert_includes log.string, "Dispatch error"
    end
  end

  def test_empty_plan_with_local_samplers_still_holds_lease
    stub_lease(granted: true, job_queues: [])
    HireFire.configuration.dyno(:worker) { 5 }
    HireFire.configuration.dispatcher

    job_queue_pass
    refute_includes log.string, "Lease grant dropped"
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

    HireFire.configuration.dispatcher
    job_queue_pass
    refute_includes log.string, "Lease grant dropped"
    session.report

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
    HireFire.configuration.dispatcher
    HireFire.configuration.buffer.sample("web", "rqt", 8)

    job_queue_pass
    assert_includes log.string, "Lease grant dropped"

    Timecop.freeze(Time.at(1000)) { session.report }
    assert_equal 1, bodies.size
    assert(bodies[0].any? { |e| e["name"] == "web" })
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

  def test_forked_child_start_reinitializes_buffer_mutex
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    dispatcher = configure_web_only
    assert dispatcher.start
    buffer = HireFire.configuration.buffer

    child_pid = Process.pid + 1
    Process.stubs(:pid).returns(child_pid)
    assert dispatcher.start

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

  def test_start_after_parent_stop_reinitializes_inherited_state
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    ENV["DYNO"] = "web.1"
    dispatcher = configure_web_only
    assert dispatcher.start
    first_cpu = HireFire.configuration.active_cpu_sources.first
    HireFire.configuration.buffer

    dispatcher.stop(flush: false)
    parent_pid = Process.pid

    Process.stubs(:pid).returns(parent_pid + 1)
    assert dispatcher.start

    refute_same first_cpu, HireFire.configuration.active_cpu_sources.first
    dispatcher.stop
  end

  def test_abandon_inherited_state_resets_always_on_sources
    stub_lease
    ENV["DYNO"] = "web.1"
    dispatcher = configure_web_only
    cpu = HireFire.configuration.active_cpu_sources.first

    dispatcher.abandon_inherited_state!

    refute_same cpu, HireFire.configuration.active_cpu_sources.first
  end

  def test_wire_payload_nested_multi_strategy_shape
    stub_lease(granted: true)
    bodies = capture_ingest_bodies

    Timecop.freeze Time.at(1000) do
      ENV["DYNO"] = "web.1"
      HireFire.configuration.dyno(:web)
      HireFire.configuration.dyno(:worker) { 3 }
      HireFire.configuration.dispatcher

      HireFire.configuration.buffer.sample("web", "rqt", 12)
      HireFire.configuration.buffer.sample("web", "cpu", 25.0)
      job_queue_pass
      session.report
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
    configure_web_only

    Timecop.freeze Time.at(1000) do
      HireFire.configuration.buffer.sample("web", "rqt", 10)
      HireFire.configuration.buffer.sample("web", "rqt", 20)
      HireFire.configuration.buffer.sample("web", "rqt", 30)
      session.report
    end

    assert_equal [20.0, 3], bodies[0][0].dig("metrics", "rqt", "1000")
  end

  def test_payload_size_limit_is_131072_with_strict_greater_drop
    limit = HireFire::Dispatcher::PAYLOAD_SIZE_LIMIT
    assert_equal 131_072, limit

    stub_lease
    ingest = stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
    configure_web_only

    Timecop.freeze Time.at(1000) do
      HireFire.configuration.buffer.sample("web", "rqt", 1)
      JSON.stubs(:generate).returns("e" * limit)
      session.report
    end
    assert_requested ingest, times: 1
    refute_includes log.string, "Dropped metrics payload"

    Timecop.freeze Time.at(1001) do
      HireFire.configuration.buffer.sample("web", "rqt", 1)
      JSON.stubs(:generate).returns("o" * (limit + 1))
      session.report
    end
    assert_requested ingest, times: 1
    assert_includes log.string, "Dropped metrics payload"
    assert_includes log.string, "#{limit + 1} bytes"
    assert_includes log.string, "exceeds the #{limit}-byte limit"
  ensure
    JSON.unstub(:generate)
  end

  def test_seven_sample_waves_of_a_full_plan_with_the_longest_names_ship_in_one_payload
    stub_lease
    sizes = []
    bodies = []
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return do |request|
      sizes << request.body.bytesize
      bodies << JSON.parse(request.body)
      {status: 200}
    end
    HireFire.configuration.dispatcher
    buffer = HireFire.configuration.buffer
    names = HireFire::Lease::MAX_JOB_QUEUES.times.map { |i| format("worker_%03d", i).ljust(HireFire::Identity::MAX_NAME_BYTES, "x") }

    [1000, 1005, 1010, 1015, 1020, 1025, 1030].each do |second|
      Timecop.freeze Time.at(second) do
        names.each do |name|
          buffer.sample(name, "jqs", 1234)
          buffer.sample(name, "wrk", 12)
        end
      end
    end
    Timecop.freeze(Time.at(1030)) { session.report }

    assert_equal 1, bodies.size
    assert_equal names, bodies[0].map { |entry| entry["name"] }
    assert(bodies[0].all? { |entry| entry["metrics"].values.map(&:size) == [7, 7] })
    assert_operator sizes[0], :>, 65_536
    refute_includes log.string, "Dropped metrics payload"
  end

  def test_a_request_queue_time_mean_over_the_limit_is_left_out_and_logged
    stub_lease
    bodies = capture_ingest_bodies
    configure_web_only

    Timecop.freeze(Time.at(1000)) { session.report }
    Timecop.freeze(Time.at(1001)) { HireFire.configuration.buffer.sample("web", "rqt", HireFire::Dispatcher::METRIC_VALUE_LIMIT * 4) }
    Timecop.freeze Time.at(1002) do
      HireFire.configuration.buffer.sample("web", "rqt", 8)
      session.report
    end

    assert_equal({"1002" => [8.0, 1]}, bodies[1][0].dig("metrics", "rqt"))
    assert_equal 1, log.string.scan("Omitting rqt second: out-of-range value.").size
  end

  def test_a_value_over_the_limit_is_left_out_and_logged_and_the_limit_itself_is_sent
    stub_lease
    bodies = capture_ingest_bodies
    limit = HireFire::Dispatcher::METRIC_VALUE_LIMIT
    assert_equal 1e15, limit

    Timecop.freeze(Time.at(999)) { HireFire.configuration.buffer.sample("worker", "jqs", limit * 2) }
    Timecop.freeze Time.at(1000) do
      HireFire.configuration.buffer.sample("worker", "jqs", limit)
      HireFire.configuration.buffer.sample("worker", "jql", 0)
      HireFire.configuration.buffer.sample("mailer", "jqs", limit * 2)
      session.report
    end

    assert_equal [{"name" => "worker", "metrics" => {"jqs" => {"1000" => limit}, "jql" => {"1000" => 0}}}], bodies[0]
    assert_equal 2, log.string.scan("Omitting jqs second: out-of-range value.").size
  end

  def test_partial_plan_unsupported_jql_and_supported_jqs_holds_and_samples_size
    size_calls = 0
    latency_calls = 0
    mod = Module.new
    mod.extend(HireFire::Plan::Hooks)
    mod.extend(HireFire::Plan::SizeOnly)
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

    HireFire.configuration.dispatcher
    job_queue_pass
    refute_includes log.string, "Lease grant dropped"
    session.report

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
    mod.extend(HireFire::Plan::SizeOnly)
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
    HireFire.configuration.dispatcher
    job_queue_pass
    job_queue_pass

    assert_equal 3, log.string.scan("does not support").size
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

    configure_web_only
    Timecop.freeze Time.at(1000) do
      HireFire.configuration.buffer.sample("web", "rqt", 7)
      session.report
    end

    data = HireFire.configuration.buffer.flush
    assert_nil data.dig("web", "rqt")
    assert_equal %w[1001 1002], seconds_claimed_at(1002)
    assert_includes log.string, "Dropped metrics payload"
  end

  def test_a_halted_session_takes_nothing_from_the_buffer_and_posts_nothing
    stub_lease
    ingest = stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
    configure_web_only
    HireFire.configuration.buffer.sample("web", "rqt", 10)

    session.halt
    session.report

    assert_not_requested ingest
    assert HireFire.configuration.buffer.flush.dig("web", "rqt")
  end

  def test_the_final_flush_of_a_halted_session_sends_what_is_buffered
    bodies = capture_ingest_bodies
    configure_web_only

    Timecop.freeze Time.at(1000) do
      HireFire.configuration.buffer.sample("web", "rqt", 7)
      session.halt(handoff: true)
      session.flush
    end

    assert_equal 1, bodies.size
    assert_equal({"1000" => [7.0, 1]}, bodies[0][0].dig("metrics", "rqt"))
  end

  def test_a_dispatch_that_fails_after_a_halt_for_a_final_flush_keeps_its_samples_for_that_flush
    bodies = []
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return do |request|
      bodies << JSON.parse(request.body)
      session.halt(handoff: true)
      {status: (bodies.size == 1) ? 500 : 200}
    end
    configure_web_only

    Timecop.freeze Time.at(1000) do
      HireFire.configuration.buffer.sample("web", "rqt", 10)
      session.report
      session.flush
    end

    assert_equal 2, bodies.size
    assert_equal({"1000" => [10.0, 1]}, bodies[1][0].dig("metrics", "rqt"))
  end

  def test_a_dispatch_that_fails_after_a_halt_without_a_final_flush_drops_its_samples
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return do |_request|
      session.halt
      {status: 500}
    end
    configure_web_only

    Timecop.freeze Time.at(1000) do
      HireFire.configuration.buffer.sample("web", "rqt", 10)
      session.report
    end

    assert_empty HireFire.configuration.buffer.flush
  end

  def test_dispatch_pacing_follows_the_monotonic_clock_not_the_wall_clock
    stub_lease
    bodies = capture_ingest_bodies
    configure_web_only

    Timecop.freeze(Time.at(1000)) do
      HireFire::Clock.stubs(:monotonic).returns(500.0)
      session.report
      HireFire::Clock.stubs(:monotonic).returns(500.9)
      session.report
      assert_equal 1, bodies.size
      HireFire::Clock.stubs(:monotonic).returns(501.0)
      session.report
    end

    assert_equal 2, bodies.size
  end

  def test_a_dispatch_pass_goes_on_when_the_lease_request_fails
    stub_request(:post, "https://data.hirefire.io/metrics/lease").to_raise(Errno::ECONNREFUSED)
    bodies = capture_ingest_bodies

    Timecop.freeze Time.at(1000) do
      configure_web_and_workers
      HireFire.configuration.buffer.sample("web", "rqt", 12)
      error = assert_raises(HireFire::Errors::RequestError) { session.renew }
      assert_includes error.message, "Network error"
      session.sample
      session.report
    end

    assert_equal 1, bodies.size
  end

  def test_a_plan_this_process_can_sample_keeps_the_grant_without_a_local_sampler
    HireFire::Plan.stubs(:executable?).with("sidekiq").returns(true)
    HireFire::Plan.stubs(:supports_strategy?).with("sidekiq", "jql").returns(true)
    stub_lease(granted: true, job_queues: [
      {"name" => "worker", "strategy" => "jql", "adapter" => "sidekiq", "queues" => ["default"], "options" => {}}
    ])

    session.renew

    refute_includes log.string, "Lease grant dropped"
  end

  def test_an_adapter_that_lists_its_own_queues_keeps_the_grant_with_an_empty_queue_list
    HireFire::Plan.stubs(:executable?).with("sidekiq").returns(true)
    HireFire::Plan.stubs(:supports_strategy?).with("sidekiq", "jqs").returns(true)
    stub_lease(granted: true, job_queues: [
      {"name" => "worker", "strategy" => "jqs", "adapter" => "sidekiq", "queues" => []}
    ])

    session.renew

    refute_includes log.string, "Lease grant dropped"
  end

  def test_a_grant_is_dropped_when_its_only_entry_needs_queue_names_and_has_none
    HireFire::Plan.stubs(:executable?).with("bunny").returns(true)
    HireFire::Plan.stubs(:supports_strategy?).with("bunny", "jqs").returns(true)
    lease = stub_lease(granted: true, job_queues: [
      {"name" => "worker", "strategy" => "jqs", "adapter" => "bunny", "queues" => [], "options" => {}}
    ])

    job_queue_pass

    assert_includes log.string, "Lease grant dropped: this process cannot sample the plan"
    assert_requested lease, times: 1
    refute_includes log.string, "requires named queues"
  end

  def test_a_grant_is_dropped_when_its_only_entry_names_a_strategy_the_adapter_lacks
    HireFire::Plan.stubs(:executable?).with("bunny").returns(true)
    HireFire::Plan.stubs(:supports_strategy?).with("bunny", "jql").returns(false)
    stub_lease(granted: true, job_queues: [
      {"name" => "worker", "strategy" => "jql", "adapter" => "bunny", "queues" => ["default"], "options" => {}}
    ])

    job_queue_pass

    assert_includes log.string, "Lease grant dropped: this process cannot sample the plan"
  end

  def test_a_grant_is_dropped_when_no_sampler_exists_and_the_adapter_is_not_loaded
    HireFire::Plan.stubs(:executable?).returns(false)
    HireFire::Plan.stubs(:known_adapter?).returns(true)
    stub_lease(granted: true, job_queues: [
      {"name" => "worker", "strategy" => "jql", "adapter" => "sidekiq", "queues" => [], "options" => {}}
    ])

    job_queue_pass

    assert_includes log.string, "Lease grant dropped: this process cannot sample the plan"
    refute_includes log.string, "is not loaded in this process"
  end

  def test_a_dropped_grant_asks_again_under_a_new_process_id
    ids = []
    stub_request(:post, "https://data.hirefire.io/metrics/lease").to_return do |request|
      ids << request.headers["Hirefire-Process-Id"]
      {status: 200, headers: {"HireFire-Lease-Granted" => "true", "HireFire-Lease-TTL" => "5"},
       body: {job_queues: [{"name" => "worker", "strategy" => "jql", "adapter" => "nope"}]}.to_json}
    end

    Timecop.freeze(Time.at(1000)) { session.renew }
    Timecop.freeze(Time.at(1005)) { session.renew }

    assert_equal 2, ids.uniq.size
  end

  def test_a_plan_adapter_without_a_local_sampler_is_sampled
    with_plan_adapters("sidekiq" => plan_adapter(job_queue_latency: 4.2)) do
      stub_lease(granted: true, job_queues: [
        {"name" => "worker", "strategy" => "jql", "adapter" => "sidekiq", "queues" => ["default"], "options" => {}}
      ])
      bodies = capture_ingest_bodies

      job_queue_pass
      session.report

      entry = bodies[0].find { |e| e["name"] == "worker" }
      assert_equal 4.2, entry.dig("metrics", "jql").values.first
      refute_includes log.string, "local sampler is ignored"
      refute_includes log.string, "UI adapter is configured"
    end
  end

  def test_an_entry_that_needs_queue_names_and_has_none_is_skipped_and_the_others_are_sampled
    calls = Hash.new(0)
    listing = plan_adapter(job_queue_size: -> { (calls["sidekiq"] += 1) + 2 })
    naming = plan_adapter(job_queue_size: -> { (calls["bunny"] += 1) - 1 })
    naming.define_singleton_method(:queues_required?) { true }

    with_plan_adapters("sidekiq" => listing, "bunny" => naming) do
      stub_lease(granted: true, job_queues: [
        {"name" => "worker", "strategy" => "jqs", "adapter" => "sidekiq", "queues" => [], "options" => {}},
        {"name" => "mail", "strategy" => "jqs", "adapter" => "bunny", "queues" => [], "options" => {}}
      ])

      job_queue_pass

      assert_equal({"sidekiq" => 1}, calls)
      assert_includes log.string, "requires named queues"
      refute_includes log.string, "Lease grant dropped"
    end
  end

  def test_a_full_plan_of_unknown_adapters_warns_once_per_entry
    assert_equal HireFire::Lease::MAX_JOB_QUEUES, HireFire::Dispatcher::WARN_MAP_LIMIT
    stub_lease(granted: true, job_queues: HireFire::Lease::MAX_JOB_QUEUES.times.map { |i|
      {"name" => "worker_#{i}", "strategy" => "jql", "adapter" => "nope", "queues" => [], "options" => {}}
    })
    HireFire.configuration.dyno(:other) { 0 }

    Timecop.freeze(Time.at(1000)) { job_queue_pass }
    Timecop.freeze(Time.at(1015)) { job_queue_pass }

    assert_equal HireFire::Lease::MAX_JOB_QUEUES, log.string.scan("Unknown plan adapter").size
  end

  def test_a_session_halted_during_a_round_samples_no_further_entry_and_traces_only_what_ran
    stub_lease(granted: true, trace: true)
    bodies = capture_ingest_bodies
    ENV["DYNO"] = "web.1"
    sampled = []
    HireFire.configuration.dyno(:worker) do
      sampled << :worker
      session.halt(handoff: true)
      42
    end
    HireFire.configuration.dyno(:mailer) { sampled << :mailer }

    job_queue_pass
    session.flush

    assert_equal [:worker], sampled
    assert_equal 1, bodies.size
    assert_equal 1, bodies[0].first["sample_trace"]["ops"].size
    refute bodies[0].any? { |row| row.dig("metrics", "jql") }
  end

  def test_a_sampler_that_raises_a_load_error_is_logged_and_the_next_entry_is_sampled
    stub_lease(granted: true)
    bodies = capture_ingest_bodies
    HireFire.configuration.dyno(:worker) { raise LoadError, "cannot load such file -- missing" }
    HireFire.configuration.dyno(:mailer) { 18 }

    job_queue_pass
    session.report

    assert_includes log.string, %(The sampler for "worker" raised LoadError: cannot load such file -- missing)
    assert_equal ["mailer"], bodies[0].map { |entry| entry["name"] }
  end

  def test_a_round_that_runs_past_its_limit_gives_up_the_lease_and_its_samples
    lease = stub_lease(granted: true)
    HireFire.configuration.dyno(:worker) do
      Timecop.freeze(Time.now + HireFire::Dispatcher::SAMPLE_ROUND_LIMIT + 1)
      session.renew
      42
    end
    HireFire.configuration.dyno(:mailer) { flunk "an entry was sampled after the lease was given up" }

    Timecop.freeze(Time.at(1000)) do
      job_queue_pass

      assert_requested lease, times: 1
      assert_equal 1, log.string.scan("A job queue sample round has run for more than 60 seconds. " \
        "The lease is released so that another process can sample.").size
      assert_empty HireFire.configuration.buffer.flush

      session.renew
      assert_requested lease, times: 2
    end
  end

  def test_a_round_inside_its_limit_keeps_the_lease
    stub_lease(granted: true)
    bodies = capture_ingest_bodies
    HireFire.configuration.dyno(:worker) do
      Timecop.freeze(Time.now + HireFire::Dispatcher::SAMPLE_ROUND_LIMIT)
      session.renew
      42
    end

    Timecop.freeze(Time.at(1000)) do
      job_queue_pass
      session.report
    end

    refute_includes log.string, "The lease is released"
    assert_equal 42.0, bodies[0].find { |entry| entry["name"] == "worker" }.dig("metrics", "jql").values.first
  end

  def test_start_replaces_a_dispatch_loop_that_ended
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
    dispatcher = configure_web_only

    assert dispatcher.start
    loop_threads("hirefire-dispatch").each { |thread| thread.kill.join }
    refute dispatcher.running?

    assert dispatcher.start
    assert dispatcher.running?
    assert_equal 1, loop_threads("hirefire-dispatch").size
    dispatcher.stop
  end

  def test_a_start_after_a_stop_runs_one_loop_of_each_kind
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
    dispatcher = configure_web_and_workers

    3.times do
      assert dispatcher.start
      wait_until { loop_threads("hirefire-lease").any? }
      assert dispatcher.stop
    end
    assert dispatcher.start
    wait_until { loop_threads("hirefire-lease").size == 1 }

    assert_equal 1, loop_threads("hirefire-dispatch").size
    dispatcher.stop
    wait_until { loop_threads("hirefire-dispatch").empty? && loop_threads("hirefire-lease").empty? }
  end

  def test_a_process_with_no_sampler_and_no_job_library_runs_no_lease_loop
    HireFire::Plan.stubs(:any_allowlisted_job_queue_library_loaded?).returns(false)
    bodies = capture_ingest_bodies
    dispatcher = configure_web_only

    with_tick(0.01) do
      assert dispatcher.start
      wait_until { bodies.any? }
      sleep(0.05)

      assert_empty loop_threads("hirefire-lease")
      dispatcher.stop
    end
  end

  def test_the_lease_loop_starts_once_a_sampler_is_registered_after_the_start
    HireFire::Plan.stubs(:any_allowlisted_job_queue_library_loaded?).returns(false)
    lease = stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
    dispatcher = configure_web_only

    with_tick(0.01) do
      assert dispatcher.start
      HireFire.configuration.dyno(:worker) { 42 }
      wait_until { loop_threads("hirefire-lease").any? }
      wait_until { WebMock::RequestRegistry.instance.times_executed(lease.request_pattern).positive? }
      dispatcher.stop
    end
  end

  def test_the_dispatch_loop_replaces_a_lease_loop_that_ended
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
    dispatcher = configure_workers_only

    with_tick(0.01) do
      assert dispatcher.start
      wait_until { loop_threads("hirefire-lease").any? }
      first = loop_threads("hirefire-lease").first
      first.kill.join

      wait_until { loop_threads("hirefire-lease").any? { |thread| !thread.equal?(first) } }
      dispatcher.stop
    end
  end

  def test_the_lease_loop_replaces_a_sample_loop_that_ended
    stub_lease(granted: true)
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
    dispatcher = configure_workers_only

    with_tick(0.01) do
      assert dispatcher.start
      wait_until { loop_threads("hirefire-sample").any? }
      first = loop_threads("hirefire-sample").first
      first.kill.join

      wait_until { loop_threads("hirefire-sample").any? { |thread| !thread.equal?(first) } }
      dispatcher.stop
    end
  end

  def test_an_exception_of_any_class_in_a_pass_is_logged_and_the_loop_goes_on
    stub_lease(granted: true)
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
    HireFire::Plan.stubs(:around_job_queue_sample).raises(Exception.new("outside every rescue"))
    dispatcher = configure_workers_only

    with_tick(0.01) do
      assert dispatcher.start
      wait_until { log.string.include?("[HireFire] Exception: outside every rescue") }
      sleep(0.05)

      assert_equal 1, loop_threads("hirefire-sample").size
      dispatcher.stop
    end
  end

  def test_the_lease_is_renewed_while_a_sample_round_is_still_running
    lease = stub_request(:post, "https://data.hirefire.io/metrics/lease").to_return(
      status: 200,
      headers: {"HireFire-Lease-Granted" => "true", "HireFire-Lease-TTL" => "5", "HireFire-Sample-Frequency" => "15"},
      body: {job_queues: [{"name" => "worker", "strategy" => "jqs"}]}.to_json
    )
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
    entered = Queue.new
    gate = Queue.new
    HireFire.configuration.dyno(:worker) do
      entered << true
      gate.pop
    end
    dispatcher = HireFire.configuration.dispatcher

    with_tick(0.01) do
      assert dispatcher.start
      Timeout.timeout(2) { entered.pop }
      Timecop.travel(Time.now + 6)

      wait_until { WebMock::RequestRegistry.instance.times_executed(lease.request_pattern) >= 2 }
      assert_equal 1, gate.num_waiting
    ensure
      Timecop.return
      gate << 7
      dispatcher.stop
    end
  end

  def test_stop_does_not_wait_for_a_sampler_that_hangs
    stub_lease(granted: true)
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
    entered = Queue.new
    gate = Queue.new
    HireFire.configuration.dyno(:worker) do
      entered << true
      gate.pop
    end
    dispatcher = HireFire.configuration.dispatcher

    assert dispatcher.start
    Timeout.timeout(2) { entered.pop }
    seconds = seconds_to { assert dispatcher.stop }

    assert_operator seconds, :<, 1
    refute_includes log.string, "final flush is skipped"
  ensure
    gate << 0
  end

  def test_stop_skips_the_final_flush_when_the_dispatch_loop_is_still_in_a_request
    entered = Queue.new
    gate = Queue.new
    ingest = stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return do |_request|
      entered << true
      gate.pop
      {status: 200}
    end
    dispatcher = configure_web_only

    with_dispatcher_const(:JOIN_TIMEOUT, 0.05) do
      assert dispatcher.start
      Timeout.timeout(2) { entered.pop }
      seconds = seconds_to { assert dispatcher.stop }

      assert_operator seconds, :<, 1
      assert_includes log.string, "The dispatch loop did not stop within 0.05 seconds. The final flush is skipped."
      assert_requested ingest, times: 1
      refute dispatcher.running?
    end
  ensure
    gate << true
  end

  def test_stop_without_flush_discards_the_buffer_and_posts_nothing_more
    bodies = capture_ingest_bodies
    dispatcher = configure_web_only

    Timecop.freeze(Time.at(1000)) do
      assert dispatcher.start
      wait_until { bodies.size == 1 }
      HireFire.configuration.buffer.sample("web", "rqt", 7)
      assert dispatcher.stop(flush: false)
    end

    assert_equal 1, bodies.size
    assert_empty HireFire.configuration.buffer.flush
    refute dispatcher.running?
  end

  def test_stop_leaves_the_dispatcher_ready_to_start_again_when_the_final_flush_raises
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
    dispatcher = configure_web_only
    HireFire::Dispatcher::Session.any_instance.stubs(:flush).raises("flush failed")

    assert dispatcher.start
    assert_raises(RuntimeError) { dispatcher.stop }
    HireFire::Dispatcher::Session.any_instance.unstub(:flush)

    assert dispatcher.start
    assert dispatcher.running?
    dispatcher.stop
  end

  def test_a_start_in_a_forked_child_drops_what_the_parent_buffered_and_begins_at_the_current_second
    stub_lease
    bodies = capture_ingest_bodies
    ENV["DYNO"] = "web.1"
    dispatcher = configure_web_only
    parent_cpu = HireFire.configuration.active_cpu_sources.first

    Timecop.freeze(Time.at(1000)) do
      assert dispatcher.start
      wait_until { bodies.size == 1 }
      HireFire.configuration.buffer.sample("web", "rqt", 7)
      child_pid = Process.pid + 1
      Process.stubs(:pid).returns(child_pid)
      Timecop.travel(Time.at(1030))
      assert dispatcher.start
      wait_until { bodies.size == 2 }
    end

    assert_equal 2, log.string.scan("Starting dispatcher.").size
    assert_equal ["1030"], bodies[1][0].dig("metrics", "rqt").keys
    refute_same parent_cpu, HireFire.configuration.active_cpu_sources.first
  end

  def test_abandoning_inherited_state_stops_reporting_and_empties_the_buffer
    stub_lease
    bodies = capture_ingest_bodies
    dispatcher = configure_web_only

    Timecop.freeze(Time.at(1000)) do
      assert dispatcher.start
      wait_until { bodies.size == 1 }
      HireFire.configuration.buffer.sample("web", "rqt", 7)
      dispatcher.abandon_inherited_state!
    end

    refute dispatcher.running?
    refute dispatcher.stop
    assert_empty HireFire.configuration.buffer.flush
    assert_equal 1, bodies.size
    assert dispatcher.start
    dispatcher.stop
  end

  def test_failed_dispatches_wait_twice_as_long_each_time_up_to_the_longest_interval
    stub_lease
    attempts = []
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return do |_request|
      attempts << Time.now.to_i
      {status: 500}
    end
    configure_web_only

    (1000..1125).each { |second| Timecop.freeze(Time.at(second)) { session.report } }

    assert_equal [1000, 1002, 1006, 1014, 1030, 1060, 1090, 1120], attempts
    assert_equal 30, HireFire::Dispatcher::MAX_DISPATCH_FREQUENCY
    assert_equal 5, HireFire::Dispatcher::BACKOFF_DOUBLINGS
  end

  def test_a_successful_dispatch_ends_the_longer_interval
    stub_lease
    attempts = []
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return do |_request|
      attempts << Time.now.to_i
      {status: (attempts.size <= 3) ? 500 : 200}
    end
    configure_web_only

    (1000..1017).each { |second| Timecop.freeze(Time.at(second)) { session.report } }

    assert_equal [1000, 1002, 1006, 1014, 1015, 1016, 1017], attempts
  end

  def test_failed_dispatches_wait_from_the_interval_the_server_set
    stub_lease
    attempts = []
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return do |_request|
      attempts << Time.now.to_i
      (attempts.size == 1) ? {status: 200, headers: {"HireFire-Dispatch-Frequency" => "5"}} : {status: 503}
    end
    configure_web_only

    (1000..1070).each { |second| Timecop.freeze(Time.at(second)) { session.report } }

    assert_equal [1000, 1005, 1015, 1035, 1065], attempts
  end

  def test_the_first_failed_dispatch_is_logged_and_later_ones_once_a_minute_with_their_count
    stub_lease
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 500)
    configure_web_only

    (1000..1059).each { |second| Timecop.freeze(Time.at(second)) { session.report } }
    assert_equal 1, log.string.scan("Dispatch error").size
    assert_includes log.string, "Dispatch error: HireFire::Errors::RequestError: Ingest request failed with 500 status.\n"

    (1060..1125).each { |second| Timecop.freeze(Time.at(second)) { session.report } }
    assert_equal ["(6 failed attempts in a row)", "(8 failed attempts in a row)"], log.string.scan(/\(\d+ failed attempts in a row\)/)
    assert_equal 60, HireFire::Dispatcher::FAILURE_LOG_INTERVAL
  end

  def test_a_recovery_after_several_failed_dispatches_is_logged_once
    stub_lease
    calls = 0
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return do |_request|
      calls += 1
      {status: (calls <= 3) ? 500 : 200}
    end
    configure_web_only

    (1000..1020).each { |second| Timecop.freeze(Time.at(second)) { session.report } }

    assert_equal 1, log.string.scan("Dispatch recovered after 3 failed attempts.").size
    assert_equal 1, log.string.scan("Dispatch error").size
  end

  def test_a_single_failed_dispatch_logs_no_recovery_line
    stub_lease
    calls = 0
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return do |_request|
      calls += 1
      {status: (calls == 1) ? 500 : 200}
    end
    configure_web_only

    (1000..1005).each { |second| Timecop.freeze(Time.at(second)) { session.report } }

    refute_includes log.string, "recovered"
    assert_equal 5, calls
  end

  def test_a_rejected_token_and_a_rejected_payload_do_not_lengthen_the_interval
    stub_lease
    attempts = []
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return do |_request|
      attempts << Time.now.to_i
      {status: attempts.size.odd? ? 401 : 413}
    end
    configure_web_only

    (1000..1004).each { |second| Timecop.freeze(Time.at(second)) { session.report } }

    assert_equal [1000, 1001, 1002, 1003, 1004], attempts
  end

  def test_a_rejected_token_follows_the_dispatch_frequency_the_server_sends_with_it
    stub_lease
    attempts = []
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return do |_request|
      attempts << Time.now.to_i
      {status: 401, headers: {"HireFire-Dispatch-Frequency" => "30"}}
    end
    configure_web_only

    (1000..1065).each { |second| Timecop.freeze(Time.at(second)) { session.report } }

    assert_equal [1000, 1030, 1060], attempts
    refute_includes log.string, "Dispatch error"
  end

  def test_a_rejected_payload_follows_the_dispatch_frequency_the_server_sends_with_it
    stub_lease
    attempts = []
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return do |_request|
      attempts << Time.now.to_i
      {status: 413, headers: {"HireFire-Dispatch-Frequency" => "10"}}
    end
    configure_web_only

    (1000..1025).each { |second| Timecop.freeze(Time.at(second)) { session.report } }

    assert_equal [1000, 1010, 1020], attempts
  end

  private

  def seconds_claimed_at(time)
    bodies = capture_ingest_bodies
    Timecop.freeze(Time.at(time)) { session.report }
    bodies.last.first.dig("metrics", "rqt").keys
  end

  def loop_threads(name)
    Thread.list.select { |thread| thread.name == name && thread.alive? }
  end

  def wait_until(seconds = 2)
    (seconds / 0.005).to_i.times do
      return if yield

      sleep(0.005)
    end
    flunk "the condition was not met within #{seconds} seconds. Log:\n#{log.string}"
  end

  def seconds_to
    started = Time.now
    yield
    Time.now - started
  end

  def with_dispatcher_const(name, value)
    original = HireFire::Dispatcher.const_get(name)
    HireFire::Dispatcher.send(:remove_const, name)
    HireFire::Dispatcher.const_set(name, value)
    yield
  ensure
    HireFire::Dispatcher.send(:remove_const, name)
    HireFire::Dispatcher.const_set(name, original)
  end

  def with_tick(seconds, &block)
    with_dispatcher_const(:TICK, seconds, &block)
  end

  def plan_adapter(samples)
    Module.new.tap do |adapter|
      adapter.extend(HireFire::Plan::Hooks)
      samples.each do |method_name, value|
        adapter.define_singleton_method(method_name) { |*_queues, **_options| value.respond_to?(:call) ? value.call : value }
      end
    end
  end

  def with_plan_adapters(adapters)
    original = HireFire::Plan::ADAPTERS
    original_checks = HireFire::Plan::LIBRARY_CHECKS
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original.merge(adapters))
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks.merge(adapters.transform_values { -> { true } }))
    yield
  ensure
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original)
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks)
  end

  def inject_oversized_series(name, strategy)
    buffer = HireFire.configuration.buffer
    1_500.times { |index| buffer.sample("p#{index}-#{"x" * 48}", strategy, 1.0) }
    buffer.sample(name, strategy, 1.0)
  end
end
