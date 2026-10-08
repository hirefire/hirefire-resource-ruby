# frozen_string_literal: true

require "test_helper"

class HireFire::LeaseTest < Minitest::Test
  def lease
    @lease ||= HireFire::Lease.new(HireFire.configuration)
  end

  def setup
    super
    ENV["HIREFIRE_TOKEN"] = "test-token-value"
    WebMock.reset_executed_requests!
    HireFire.configuration.logger = Logger.new(StringIO.new)
  end

  def request_at(seconds)
    Timecop.freeze(Time.at(1000 + seconds)) { lease.request_if_due(hold: ->(_) { true }) }
  end

  def sampled_at?(seconds)
    sampled = false
    Timecop.freeze(Time.at(1000 + seconds)) { lease.sample_if_due { sampled = true } }
    sampled
  end

  def test_process_id_is_stable_hex
    assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/, lease.process_id)
    assert_equal lease.process_id, lease.process_id
  end

  def test_not_granted_by_default
    refute lease.granted?
  end

  def test_granted_after_successful_poll
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      })

    lease.request_if_due(hold: ->(_) { true })

    assert lease.granted?
  end

  def test_denied_after_poll
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "false",
        "HireFire-Sample-Frequency" => "15"
      })

    lease.request_if_due(hold: ->(_) { true })

    refute lease.granted?
  end

  def test_updates_sample_frequency_from_response
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "false",
        "HireFire-Sample-Frequency" => "30"
      })

    lease.request_if_due(hold: ->(_) { true })

    assert_equal 30, lease.sample_frequency
  end

  def test_the_ttl_of_a_response_sets_when_the_next_request_goes_out
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "false",
        "HireFire-Lease-TTL" => "30"
      })

    request_at(0)
    request_at(29)
    assert_requested(:post, "https://data.hirefire.io/metrics/lease", times: 1)

    request_at(30)
    assert_requested(:post, "https://data.hirefire.io/metrics/lease", times: 2)
  end

  def test_not_polled_before_interval_elapsed
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "false",
        "HireFire-Sample-Frequency" => "15"
      })

    lease.request_if_due(hold: ->(_) { true })
    lease.request_if_due(hold: ->(_) { true })

    assert_requested(:post, "https://data.hirefire.io/metrics/lease", times: 1)
  end

  def test_silently_denied_on_unauthorized
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 401)

    lease.request_if_due(hold: ->(_) { true })

    refute lease.granted?
  end

  def test_revokes_granted_lease_on_unauthorized
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(
        {status: 200, headers: {"HireFire-Lease-Granted" => "true", "HireFire-Sample-Frequency" => "15"}},
        {status: 401}
      )

    lease.request_if_due(hold: ->(_) { true })
    assert lease.granted?

    Timecop.travel(Time.now + 15) do
      lease.request_if_due(hold: ->(_) { true })
      refute lease.granted?
    end
  end

  def test_transport_failure_demotes_and_waits_a_full_ttl
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_raise(Errno::ECONNREFUSED)

    assert_raises(HireFire::Errors::RequestError) { lease.request_if_due(hold: ->(_) { true }) }
    refute lease.granted?

    lease.request_if_due(hold: ->(_) { true })

    assert_requested(:post, "https://data.hirefire.io/metrics/lease", times: 1)
  end

  def test_transport_failure_revokes_granted_lease
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      })

    lease.request_if_due(hold: ->(_) { true })
    assert lease.granted?

    stub_request(:post, "https://data.hirefire.io/metrics/lease").to_timeout

    Timecop.travel(Time.now + 15) do
      assert_raises(HireFire::Errors::RequestError) { lease.request_if_due(hold: ->(_) { true }) }
      refute lease.granted?
    end
  end

  def test_the_ttl_of_a_response_stays_when_a_later_response_carries_none
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(
        {status: 200, headers: {"HireFire-Lease-Granted" => "true", "HireFire-Lease-TTL" => "30"}},
        {status: 200, headers: {"HireFire-Lease-Granted" => "true"}}
      )

    request_at(0)
    request_at(30)
    request_at(59)
    assert_requested(:post, "https://data.hirefire.io/metrics/lease", times: 2)

    request_at(60)
    assert_requested(:post, "https://data.hirefire.io/metrics/lease", times: 3)
  end

  def test_raises_on_server_error
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 500)

    error = assert_raises(HireFire::Errors::RequestError) do
      lease.request_if_due(hold: ->(_) { true })
    end

    assert_equal "Lease request failed with 500 status.", error.message
    refute lease.granted?
  end

  def test_a_new_lease_has_no_grant_no_trace_and_no_plan
    refute lease.granted?
    assert_equal false, lease.trace?
    assert_equal [], lease.job_queues
    assert_equal 15, lease.sample_frequency
  end

  def test_a_request_reports_whether_a_response_was_applied
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {"HireFire-Lease-Granted" => "false"})

    assert_equal true, request_at(0)
    assert_nil request_at(1)
  end

  def test_a_denied_response_keeps_no_plan_and_no_trace_and_does_not_ask_whether_the_plan_can_be_sampled
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {"HireFire-Lease-Granted" => "false"},
        body: {trace: true, job_queues: [{"name" => "worker", "strategy" => "jql"}]}.to_json)
    process_id = lease.process_id

    lease.request_if_due(hold: ->(_) { flunk "a denied response must not ask" })

    refute lease.granted?
    assert_equal false, lease.trace?
    assert_equal [], lease.job_queues
    assert_equal process_id, lease.process_id
    assert_empty log.string
  end

  def test_a_grant_that_can_no_longer_be_sampled_ends_the_grant_held_before
    body = {job_queues: [{"name" => "worker", "strategy" => "jql"}]}.to_json
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {"HireFire-Lease-Granted" => "true", "HireFire-Lease-TTL" => "5"}, body: body)
    holds = [true, false].each

    Timecop.freeze(Time.at(1000)) { lease.request_if_due(hold: ->(_) { holds.next }) }
    assert lease.granted?
    Timecop.freeze(Time.at(1005)) { lease.request_if_due(hold: ->(_) { holds.next }) }

    refute lease.granted?
    assert_equal [], lease.job_queues
  end

  def test_a_forked_child_does_not_sample_under_the_grant_it_inherited
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {"HireFire-Lease-Granted" => "true"})
    lease.request_if_due(hold: ->(_) { true })
    child_pid = Process.pid + 1
    Process.stubs(:pid).returns(child_pid)

    lease.sample_if_due { flunk "the child sampled under the grant of its parent" }

    refute lease.granted?
  end

  def test_a_grant_with_an_empty_body_holds_with_an_empty_plan_and_logs_nothing
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {"HireFire-Lease-Granted" => "true"}, body: "")

    lease.request_if_due(hold: ->(_) { true })

    assert lease.granted?
    assert_equal false, lease.trace?
    assert_equal [], lease.job_queues
    assert_empty log.string
  end

  def test_a_plan_that_is_not_a_list_is_ignored_with_its_reason_and_the_trace_flag_is_kept
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {"HireFire-Lease-Granted" => "true"}, body: {trace: true, job_queues: "worker"}.to_json)

    lease.request_if_due(hold: ->(_) { true })

    assert lease.granted?
    assert_equal true, lease.trace?
    assert_equal [], lease.job_queues
    assert_includes log.string, "[HireFire] Lease grant body job_queues was not an array. Plan ignored."
  end

  def test_a_body_that_cannot_be_read_grants_without_a_trace
    ["not-json{", "[1, 2]"].each do |body|
      @lease = nil
      stub_request(:post, "https://data.hirefire.io/metrics/lease")
        .to_return(status: 200, headers: {"HireFire-Lease-Granted" => "true"}, body: body)

      lease.request_if_due(hold: ->(_) { true })

      assert lease.granted?
      assert_equal false, lease.trace?, body
    end
  end

  def test_entries_that_are_not_objects_are_skipped_and_counted
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {"HireFire-Lease-Granted" => "true"},
        body: {job_queues: [5, [1], "worker", nil, {"name" => "worker", "strategy" => "jql"}]}.to_json)

    lease.request_if_due(hold: ->(_) { true })

    assert_equal ["worker"], lease.job_queues.map { |entry| entry["name"] }
    assert_includes log.string, "[HireFire] Lease plan skipped 4 invalid job queue entries."
  end

  def test_losing_the_grant_also_ends_the_trace
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(
        {status: 200, headers: {"HireFire-Lease-Granted" => "true", "HireFire-Lease-TTL" => "5"}, body: {trace: true, job_queues: []}.to_json},
        {status: 401}
      )

    request_at(0)
    assert_equal true, lease.trace?
    request_at(5)

    refute lease.granted?
    assert_equal false, lease.trace?
  end

  def test_sends_process_id_header
    request = stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .with(headers: {"HireFire-Process-ID" => lease.process_id})
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "false",
        "HireFire-Sample-Frequency" => "15"
      })

    lease.request_if_due(hold: ->(_) { true })

    assert_requested request
  end

  def test_hold_false_drops_grant_without_sampling
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      }, body: {version: 1, job_queues: []}.to_json)

    original_process_id = lease.process_id
    lease.request_if_due(hold: ->(_) { false })

    refute lease.granted?
    assert_empty lease.job_queues
    refute_equal original_process_id, lease.process_id
  end

  def test_sample_frequency_decrease_pulls_next_sample_forward
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(
        {status: 200, headers: {"HireFire-Lease-Granted" => "true", "HireFire-Sample-Frequency" => "60", "HireFire-Lease-TTL" => "5"}},
        {status: 200, headers: {"HireFire-Lease-Granted" => "true", "HireFire-Sample-Frequency" => "2", "HireFire-Lease-TTL" => "5"}}
      )

    request_at(0)
    assert sampled_at?(0)
    request_at(5)

    assert_equal 2, lease.sample_frequency
    refute sampled_at?(6)
    assert sampled_at?(7)
  end

  def test_demote_clears_grant_and_invalidates_inflight_epoch
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      }, body: {version: 1, job_queues: [{"name" => "worker", "strategy" => "jql"}]}.to_json)

    lease.request_if_due(hold: ->(_) { true })
    assert lease.granted?

    lease.demote!
    refute lease.granted?
    assert_empty lease.job_queues
  end

  def test_demote_during_inflight_request_discards_late_grant
    target = lease
    stub_request(:post, "https://data.hirefire.io/metrics/lease").to_return do |_request|
      target.demote!
      {
        status: 200,
        headers: {"HireFire-Lease-Granted" => "true", "HireFire-Sample-Frequency" => "30", "HireFire-Lease-TTL" => "120"},
        body: {version: 1, job_queues: [{"name" => "worker", "strategy" => "jql"}]}.to_json
      }
    end

    refute target.request_if_due(hold: ->(_) { true })

    refute target.granted?
    assert_empty target.job_queues
    assert_equal 15, target.sample_frequency
  end

  def test_regrant_rearms_next_sample_immediately
    granted = {status: 200, headers: {"HireFire-Lease-Granted" => "true", "HireFire-Sample-Frequency" => "60", "HireFire-Lease-TTL" => "15"}}
    denied = {status: 200, headers: {"HireFire-Lease-Granted" => "false", "HireFire-Sample-Frequency" => "60", "HireFire-Lease-TTL" => "15"}}
    stub_request(:post, "https://data.hirefire.io/metrics/lease").to_return(granted, denied, granted)

    request_at(0)
    assert sampled_at?(0)
    refute sampled_at?(14)

    request_at(15)
    refute lease.granted?

    request_at(30)
    assert lease.granted?
    assert sampled_at?(30)
  end

  def test_parse_strips_entry_identity_fields
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      }, body: {
        version: 1,
        job_queues: [{
          "name" => "  worker  ",
          "strategy" => "  jql  ",
          "adapter" => "  sidekiq  ",
          "queues" => ["default"]
        }]
      }.to_json)

    lease.request_if_due(hold: ->(_) { true })

    assert lease.granted?
    entry = lease.job_queues.first
    assert_equal "worker", entry["name"]
    assert_equal "jql", entry["strategy"]
    assert_equal "sidekiq", entry["adapter"]
  end

  def test_wrong_shape_plan_body_logs
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)

    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      }, body: "[1,2,3]")

    lease.request_if_due(hold: ->(_) { true })

    assert_empty lease.job_queues
    assert_includes log.string, "not a JSON object"
  end

  def test_parses_grant_job_queues_body
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      }, body: {
        version: 1,
        job_queues: [{"name" => "worker", "strategy" => "jql", "adapter" => "sidekiq", "queues" => ["default"], "options" => {}}]
      }.to_json)

    lease.request_if_due(hold: ->(_) { true })

    assert lease.granted?
    refute lease.trace?
    assert_equal 1, lease.job_queues.size
    assert_equal "worker", lease.job_queues[0]["name"]
    assert_equal "sidekiq", lease.job_queues[0]["adapter"]
  end

  def test_parses_hyphenated_job_queue_name
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      }, body: {
        version: 1,
        job_queues: [{"name" => "worker-latency", "strategy" => "jql"}]
      }.to_json)

    lease.request_if_due(hold: ->(_) { true })

    assert lease.granted?
    assert_equal 1, lease.job_queues.size
    assert_equal "worker-latency", lease.job_queues[0]["name"]
  end

  def test_parses_grant_trace_true
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      }, body: {
        version: 1,
        trace: true,
        job_queues: [{"name" => "worker", "strategy" => "jql"}]
      }.to_json)

    lease.request_if_due(hold: ->(_) { true })

    assert lease.granted?
    assert lease.trace?
  end

  def test_trace_false_for_string_or_missing
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      }, body: {
        version: 1,
        trace: "true",
        job_queues: []
      }.to_json)

    lease.request_if_due(hold: ->(_) { true })

    assert lease.granted?
    refute lease.trace?
  end

  def test_an_oversized_grant_body_fails_the_request_and_grants_nothing
    oversized = "x" * (HireFire::Client::MAX_BODY_BYTES + 1)

    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "30"
      }, body: oversized)

    error = assert_raises(HireFire::Errors::RequestError) do
      lease.request_if_due(hold: ->(_) { true })
    end

    assert_equal "Response body exceeded 131072 bytes (status 200).", error.message
    refute lease.granted?
    assert_empty lease.job_queues
    assert_equal 15, lease.sample_frequency
  end

  def test_accepts_grant_body_of_exactly_max_body_bytes
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)
    body = {version: 1, job_queues: [
      {"name" => "worker", "strategy" => "jql", "adapter" => nil, "queues" => [], "options" => {}}
    ]}.to_json
    body += " " * (HireFire::Client::MAX_BODY_BYTES - body.bytesize)

    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      }, body: body)

    lease.request_if_due(hold: ->(_) { true })

    assert_equal ["worker"], lease.job_queues.map { |entry| entry["name"] }
    assert_empty log.string
  end

  def test_accepts_a_plan_of_max_job_queues_with_three_queues_each
    assert_equal 256, HireFire::Lease::MAX_JOB_QUEUES

    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)
    entries = HireFire::Lease::MAX_JOB_QUEUES.times.map do |i|
      {
        "name" => "background_worker_#{i}",
        "strategy" => "jqs",
        "adapter" => "sidekiq",
        "queues" => ["critical_#{i}", "default_#{i}", "low_priority_#{i}"],
        "options" => {"skip_working" => true}
      }
    end
    body = {version: 1, job_queues: entries}.to_json
    assert_operator body.bytesize, :>, 32_768

    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      }, body: body)

    lease.request_if_due(hold: ->(_) { true })

    assert_equal entries, lease.job_queues
    assert_empty log.string
  end

  def test_truncates_plan_to_max_job_queues
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)
    entries = (HireFire::Lease::MAX_JOB_QUEUES + 3).times.map do |i|
      {"name" => "w#{i}", "strategy" => "jql", "adapter" => nil, "queues" => [], "options" => {}}
    end

    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      }, body: {version: 1, job_queues: entries}.to_json)

    lease.request_if_due(hold: ->(_) { true })

    assert_equal HireFire::Lease::MAX_JOB_QUEUES, lease.job_queues.size
    assert_equal "w255", lease.job_queues.last["name"]
    assert_includes log.string, "Lease plan truncated to 256 job queue entries.\n"
  end

  def test_truncation_counts_only_the_invalid_entries_as_invalid
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)
    entries = Array.new(HireFire::Lease::MAX_JOB_QUEUES + 1) { |i| {"name" => "w#{i}", "strategy" => "jql"} }
    entries.insert(3, "not-a-hash", {"name" => "", "strategy" => "jql"})

    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {"HireFire-Lease-Granted" => "true"}, body: {job_queues: entries}.to_json)

    lease.request_if_due(hold: ->(_) { true })

    assert_equal HireFire::Lease::MAX_JOB_QUEUES, lease.job_queues.size
    assert_includes log.string, "Lease plan truncated to 256 job queue entries (2 invalid also skipped).\n"
  end

  def test_a_plan_at_the_limit_after_invalid_entries_are_skipped_is_not_truncated
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)
    entries = Array.new(HireFire::Lease::MAX_JOB_QUEUES) { |i| {"name" => "w#{i}", "strategy" => "jql"} }
    entries << "not-a-hash"

    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {"HireFire-Lease-Granted" => "true"}, body: {job_queues: entries}.to_json)

    lease.request_if_due(hold: ->(_) { true })

    assert_equal HireFire::Lease::MAX_JOB_QUEUES, lease.job_queues.size
    assert_includes log.string, "Lease plan skipped 1 invalid job queue entry.\n"
    refute_includes log.string, "truncated"
  end

  def test_skips_invalid_plan_entries
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)
    long_name = "a" * (HireFire::Identity::MAX_NAME_BYTES + 1)

    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      }, body: {
        version: 1,
        job_queues: [
          "not-a-hash",
          {"name" => "", "strategy" => "jql"},
          {"name" => "ok", "strategy" => ""},
          {"name" => long_name, "strategy" => "jql"},
          {"name" => "worker", "strategy" => "jql", "adapter" => nil, "queues" => [], "options" => {}}
        ]
      }.to_json)

    lease.request_if_due(hold: ->(_) { true })

    assert_equal 1, lease.job_queues.size
    assert_equal "worker", lease.job_queues[0]["name"]
    assert_includes log.string, "skipped"
  end

  def test_a_name_of_exactly_the_longest_length_is_kept
    longest = "a" * HireFire::Identity::MAX_NAME_BYTES
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {"HireFire-Lease-Granted" => "true"},
        body: {version: 1, job_queues: [{"name" => longest, "strategy" => "jqs"}]}.to_json)

    lease.request_if_due(hold: ->(_) { true })

    assert_equal [longest], lease.job_queues.map { |entry| entry["name"] }
  end

  def test_an_entry_without_an_adapter_gets_none
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {"HireFire-Lease-Granted" => "true"},
        body: {version: 1, job_queues: [{"name" => " worker ", "strategy" => "jqs"}]}.to_json)

    lease.request_if_due(hold: ->(_) { true })

    assert_equal [{"name" => "worker", "strategy" => "jqs"}], lease.job_queues
  end

  def test_json_null_adapter_is_strategy_only
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      }, body: {
        version: 1,
        job_queues: [
          {"name" => "worker", "strategy" => "jql", "adapter" => nil, "queues" => [], "options" => {}}
        ]
      }.to_json)

    lease.request_if_due(hold: ->(_) { true })

    assert_equal 1, lease.job_queues.size
    assert_equal "worker", lease.job_queues[0]["name"]
    assert_equal "", lease.job_queues[0]["adapter"]
  end

  def test_json_null_name_or_strategy_is_skipped
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)

    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      }, body: {
        version: 1,
        job_queues: [
          {"name" => nil, "strategy" => "jql", "adapter" => nil},
          {"name" => "worker", "strategy" => nil, "adapter" => nil},
          {"name" => "ok", "strategy" => "jql", "adapter" => nil, "queues" => [], "options" => {}}
        ]
      }.to_json)

    lease.request_if_due(hold: ->(_) { true })

    assert_equal 1, lease.job_queues.size
    assert_equal "ok", lease.job_queues[0]["name"]
    assert_includes log.string, "skipped"
  end

  def test_invalid_json_grant_body_is_ignored
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)

    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      }, body: "{not-json")

    lease.request_if_due(hold: ->(_) { true })

    assert lease.granted?
    assert_empty lease.job_queues
    assert_includes log.string, "not valid JSON"
  end

  def test_sample_if_due_yields_when_granted_and_due
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      })

    lease.request_if_due(hold: ->(_) { true })
    sampled = false
    lease.sample_if_due { sampled = true }

    assert sampled
  end

  def test_sample_if_due_skips_when_not_granted
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "false",
        "HireFire-Sample-Frequency" => "15"
      })

    lease.request_if_due(hold: ->(_) { true })
    sampled = false
    lease.sample_if_due { sampled = true }

    refute sampled
  end

  def test_sample_if_due_skips_when_not_yet_due
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      })

    lease.request_if_due(hold: ->(_) { true })
    lease.sample_if_due {}

    sampled = false
    lease.sample_if_due { sampled = true }

    refute sampled
  end

  def test_failed_sample_consumes_its_window
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      })

    lease.request_if_due(hold: ->(_) { true })

    assert_raises(RuntimeError) { lease.sample_if_due { raise "boom" } }

    sampled = false
    lease.sample_if_due { sampled = true }

    refute sampled
  end

  def test_a_sample_is_due_again_one_sample_frequency_after_the_last
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "10"
      })

    request_at(0)

    assert sampled_at?(0)
    refute sampled_at?(9)
    assert sampled_at?(10)
  end

  def test_retains_sample_frequency_when_the_header_is_absent
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {"HireFire-Lease-Granted" => "true"})

    lease.request_if_due(hold: ->(_) { true })

    assert lease.granted?
    assert_equal 15, lease.sample_frequency
  end

  def test_grants_only_on_a_literal_true
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "1",
        "HireFire-Sample-Frequency" => "15"
      })

    lease.request_if_due(hold: ->(_) { true })

    refute lease.granted?
  end

  def test_ignores_a_sample_frequency_that_is_not_a_positive_integer
    ["0", "-5", "soon", "3abc", "1.5", "1_000", ""].each do |value|
      stub_request(:post, "https://data.hirefire.io/metrics/lease")
        .to_return(status: 200, headers: {
          "HireFire-Lease-Granted" => "true",
          "HireFire-Sample-Frequency" => value
        })
      lease = HireFire::Lease.new(HireFire.configuration)

      lease.request_if_due(hold: ->(_) { true })

      assert_equal 15, lease.sample_frequency, "a sample frequency of #{value.inspect} was applied"
      assert lease.granted?
    end
  end

  def test_accepts_a_sample_frequency_with_surrounding_whitespace
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => " 30 "
      })

    lease.request_if_due(hold: ->(_) { true })

    assert_equal 30, lease.sample_frequency
  end

  def test_clamps_an_over_large_sample_frequency_to_the_ceiling
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "99999"
      })

    lease.request_if_due(hold: ->(_) { true })

    assert_equal HireFire::Lease::SAMPLE_FREQUENCY_BOUNDS.end, lease.sample_frequency
  end

  def test_ignores_a_ttl_that_is_not_a_positive_integer
    ["0", "-5", "abc", "3abc", "1.5", ""].each do |value|
      stub_request(:post, "https://data.hirefire.io/metrics/lease")
        .to_return(status: 200, headers: {
          "HireFire-Lease-Granted" => "true",
          "HireFire-Lease-TTL" => value
        })
      lease = Timecop.freeze(Time.at(1000)) { HireFire::Lease.new(HireFire.configuration) }

      Timecop.freeze(Time.at(1000)) { lease.request_if_due(hold: ->(_) { true }) }
      Timecop.freeze(Time.at(1014)) { lease.request_if_due(hold: ->(_) { true }) }
      assert_requested(:post, "https://data.hirefire.io/metrics/lease", times: 1)
      Timecop.freeze(Time.at(1015)) { lease.request_if_due(hold: ->(_) { true }) }
      assert_requested(:post, "https://data.hirefire.io/metrics/lease", times: 2)
      WebMock.reset_executed_requests!
    end
  end

  def test_clamps_a_ttl_below_the_floor_to_the_floor
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Lease-TTL" => "1"
      })

    Timecop.freeze(Time.at(1000)) { lease.request_if_due(hold: ->(_) { true }) }
    Timecop.freeze(Time.at(1004)) { lease.request_if_due(hold: ->(_) { true }) }
    assert_requested(:post, "https://data.hirefire.io/metrics/lease", times: 1)
    Timecop.freeze(Time.at(1005)) { lease.request_if_due(hold: ->(_) { true }) }
    assert_requested(:post, "https://data.hirefire.io/metrics/lease", times: 2)
  end

  def test_clamps_an_over_large_ttl_to_the_ceiling
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Lease-TTL" => "99999"
      })

    request_at(0)
    request_at(HireFire::Lease::TTL_BOUNDS.end - 1)
    assert_requested(:post, "https://data.hirefire.io/metrics/lease", times: 1)

    request_at(HireFire::Lease::TTL_BOUNDS.end)
    assert_requested(:post, "https://data.hirefire.io/metrics/lease", times: 2)
  end

  def test_close_closes_its_client
    HireFire::Client.any_instance.expects(:close).once

    lease.close
  end

  def test_unauthorized_ignores_frequency_and_ttl_headers
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 401, headers: {
        "HireFire-Sample-Frequency" => "99",
        "HireFire-Lease-TTL" => "99"
      })

    lease.request_if_due(hold: ->(_) { true })

    refute lease.granted?
    assert_equal 15, lease.sample_frequency
  end

  def test_expiry_paces_off_the_monotonic_clock_not_the_wall_clock
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Lease-TTL" => "30"
      })

    HireFire::Clock.stubs(:monotonic).returns(5000.0)
    lease.request_if_due(hold: ->(_) { true })

    HireFire::Clock.stubs(:monotonic).returns(5029.0)
    Timecop.freeze(Time.now + 3600) { lease.request_if_due(hold: ->(_) { true }) }
    assert_requested(:post, "https://data.hirefire.io/metrics/lease", times: 1)

    HireFire::Clock.stubs(:monotonic).returns(5030.0)
    Timecop.freeze(Time.now - 3600) { lease.request_if_due(hold: ->(_) { true }) }
    assert_requested(:post, "https://data.hirefire.io/metrics/lease", times: 2)
  end

  def test_forked_child_reissues_identity_and_re_requests_the_lease
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      })

    lease.request_if_due(hold: ->(_) { true })
    assert lease.granted?
    original_process_id = lease.process_id
    child_pid = Process.pid + 1
    Process.stubs(:pid).returns(child_pid)

    2.times { lease.request_if_due(hold: ->(_) { true }) }

    refute_equal original_process_id, lease.process_id
    assert_requested(:post, "https://data.hirefire.io/metrics/lease", times: 2)
    assert_requested(:post, "https://data.hirefire.io/metrics/lease",
      headers: {"HireFire-Process-ID" => lease.process_id}, times: 1)
  end

  def test_unauthorized_clears_prior_job_queues
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(
        {
          status: 200,
          headers: {"HireFire-Lease-Granted" => "true", "HireFire-Sample-Frequency" => "15"},
          body: {version: 1, job_queues: [{"name" => "worker", "strategy" => "jql"}]}.to_json
        },
        {status: 401}
      )

    lease.request_if_due(hold: ->(_) { true })
    assert lease.granted?
    refute_empty lease.job_queues

    Timecop.travel(Time.now + 15) do
      lease.request_if_due(hold: ->(_) { true })
      refute lease.granted?
      assert_empty lease.job_queues
    end
  end

  def test_deny_after_grant_clears_job_queues_plan
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(
        {
          status: 200,
          headers: {"HireFire-Lease-Granted" => "true", "HireFire-Sample-Frequency" => "15"},
          body: {version: 1, job_queues: [
            {"name" => "worker", "strategy" => "jql", "adapter" => "sidekiq", "queues" => [], "options" => {}}
          ]}.to_json
        },
        {
          status: 200,
          headers: {"HireFire-Lease-Granted" => "false", "HireFire-Sample-Frequency" => "15"},
          body: ""
        }
      )

    lease.request_if_due(hold: ->(_) { true })
    assert lease.granted?
    refute_empty lease.job_queues

    Timecop.travel(Time.now + 15) do
      lease.request_if_due(hold: ->(_) { true })
      refute lease.granted?
      assert_empty lease.job_queues
    end
  end

  def test_transport_failure_clears_prior_job_queues
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      }, body: {version: 1, job_queues: [{"name" => "worker", "strategy" => "jql"}]}.to_json)

    lease.request_if_due(hold: ->(_) { true })
    refute_empty lease.job_queues

    stub_request(:post, "https://data.hirefire.io/metrics/lease").to_timeout
    Timecop.travel(Time.now + 15) do
      assert_raises(HireFire::Errors::RequestError) { lease.request_if_due(hold: ->(_) { true }) }
      refute lease.granted?
      assert_empty lease.job_queues
    end
  end

  def test_non_object_or_non_array_plan_body_yields_empty_job_queues
    [
      [].to_json,
      '"string"'.to_json,
      {version: 1, job_queues: {}}.to_json
    ].each do |body|
      lease = HireFire::Lease.new(HireFire.configuration)
      stub_request(:post, "https://data.hirefire.io/metrics/lease")
        .to_return(status: 200, headers: {
          "HireFire-Lease-Granted" => "true",
          "HireFire-Sample-Frequency" => "15"
        }, body: body)

      lease.request_if_due(hold: ->(_) { true })
      assert lease.granted?, body
      assert_empty lease.job_queues, body
    end
  end

  def test_hold_receives_parsed_job_queues
    received = nil
    entry = {"name" => "worker", "strategy" => "jql", "adapter" => "sidekiq", "queues" => ["default"], "options" => {}}
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      }, body: {version: 1, job_queues: [entry]}.to_json)

    lease.request_if_due(hold: ->(queues) {
      received = queues
      true
    })

    assert_equal 1, received.size
    assert_equal "worker", received[0]["name"]
    assert_equal "sidekiq", received[0]["adapter"]
  end

  def test_skips_single_invalid_entry_log_uses_singular
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)

    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      }, body: {
        version: 1,
        job_queues: [
          {"name" => "", "strategy" => "jql"},
          {"name" => "worker", "strategy" => "jql"}
        ]
      }.to_json)

    lease.request_if_due(hold: ->(_) { true })

    assert_equal 1, lease.job_queues.size
    assert_includes log.string, "skipped 1 invalid job queue entry"
  end

  def test_a_plan_problem_at_every_response_is_logged_once_a_minute_and_once_when_a_plan_reads_again
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)
    bodies = Array.new(13, "{not json") + [JSON.generate("job_queues" => [1]), JSON.generate("job_queues" => [])]
    stub_request(:post, "https://data.hirefire.io/metrics/lease").to_return do |_request|
      {status: 200, headers: {"HireFire-Lease-Granted" => "true", "HireFire-Lease-TTL" => "5"}, body: bodies.shift}
    end
    Timecop.freeze(Time.at(1000)) { lease }

    (0..55).step(5) { |seconds| request_at(seconds) }
    assert_equal ["[HireFire] Lease grant body was not valid JSON. Plan ignored.\n"], log.string.lines.map { |line| line[/\[HireFire\].*/m] }

    request_at(60)
    assert_includes log.string, "Lease grant body was not valid JSON. Plan ignored. (13 failed attempts in a row)\n"

    request_at(65)
    refute_includes log.string, "Lease plan skipped"
    refute_includes log.string, "recovered"

    request_at(70)
    assert_equal 1, log.string.scan("Lease plan recovered after 14 failed attempts.\n").size
  end
end
