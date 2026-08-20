# frozen_string_literal: true

require "test_helper"

class HireFire::LeaseTest < Minitest::Test
  def lease
    @lease ||= HireFire::Lease.new
  end

  def setup
    super
    ENV["HIREFIRE_TOKEN"] = "test-token-value"
    WebMock.reset_executed_requests!
    HireFire.configuration.logger = Logger.new(StringIO.new)
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

  def test_updates_ttl_from_response
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "false",
        "HireFire-Lease-TTL" => "30"
      })

    lease.request_if_due(hold: ->(_) { true })

    assert_equal 30, lease.instance_variable_get(:@ttl)
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

    assert_raises(HireFire::Client::RequestError) { lease.request_if_due(hold: ->(_) { true }) }
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
      assert_raises(HireFire::Client::RequestError) { lease.request_if_due(hold: ->(_) { true }) }
      refute lease.granted?
    end
  end

  def test_ttl_update_applies_to_the_current_window
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Lease-TTL" => "30"
      })

    lease.request_if_due(hold: ->(_) { true })

    expected = Time.now + 30
    actual = lease.instance_variable_get(:@expires_at)
    assert_in_delta expected.to_f, actual.to_f, 1
  end

  def test_raises_on_server_error
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 500)

    error = assert_raises(HireFire::Client::RequestError) do
      lease.request_if_due(hold: ->(_) { true })
    end

    assert_includes error.message, "Lease request failed"
    refute lease.granted?
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
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15",
        "HireFire-Lease-TTL" => "60"
      }, body: {version: 1, job_queues: []}.to_json)
      .then
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "1",
        "HireFire-Lease-TTL" => "60"
      }, body: {version: 1, job_queues: []}.to_json)

    lease.request_if_due(hold: ->(_) { true })
    assert lease.granted?
    lease.sample_if_due { :sampled }
    far_deadline = lease.instance_variable_get(:@next_sample_at)

    lease.instance_variable_set(:@expires_at, HireFire::Clock.monotonic - 1)
    lease.request_if_due(hold: ->(_) { true })

    assert_equal 1, lease.sample_frequency
    sooner = lease.instance_variable_get(:@next_sample_at)
    assert_operator sooner, :<, far_deadline
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
    client = target.instance_variable_get(:@client)
    client.define_singleton_method(:request_lease) do |_process_id|
      target.demote!
      response = Net::HTTPOK.new("1.1", "200", "OK")
      response.instance_variable_set(:@read, true)
      body = {version: 1, job_queues: [{"name" => "worker", "strategy" => "jql"}]}.to_json
      headers = {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "30",
        "HireFire-Lease-TTL" => "120"
      }
      response.define_singleton_method(:body) { body }
      response.define_singleton_method(:[]) { |key| headers[key] }
      response.define_singleton_method(:key?) { |key| headers.key?(key) }
      response
    end

    target.request_if_due(hold: ->(_) { true })

    refute target.granted?
    assert_empty target.job_queues
    assert_equal 15, target.sample_frequency
  end

  def test_regrant_rearms_next_sample_immediately
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "60",
        "HireFire-Lease-TTL" => "15"
      }, body: {version: 1, job_queues: []}.to_json)
      .then
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "false",
        "HireFire-Sample-Frequency" => "60",
        "HireFire-Lease-TTL" => "15"
      }, body: "")
      .then
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "60",
        "HireFire-Lease-TTL" => "15"
      }, body: {version: 1, job_queues: []}.to_json)

    lease.request_if_due(hold: ->(_) { true })
    assert lease.granted?
    lease.sample_if_due { :sampled }
    far = lease.instance_variable_get(:@next_sample_at)
    assert_operator far, :>, HireFire::Clock.monotonic + 30

    lease.instance_variable_set(:@expires_at, HireFire::Clock.monotonic - 1)
    lease.request_if_due(hold: ->(_) { true })
    refute lease.granted?

    lease.instance_variable_set(:@expires_at, HireFire::Clock.monotonic - 1)
    lease.request_if_due(hold: ->(_) { true })
    assert lease.granted?

    rearmed = lease.instance_variable_get(:@next_sample_at)
    assert_operator rearmed, :<=, HireFire::Clock.monotonic + 1
    assert_operator rearmed, :<, far
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

  def test_ignores_oversized_grant_body
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)
    oversized = "x" * (HireFire::Lease::MAX_BODY_BYTES + 1)

    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      }, body: oversized)

    lease.request_if_due(hold: ->(_) { true })

    assert lease.granted?
    assert_empty lease.job_queues
    assert_includes log.string, "exceeded"
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
    assert_includes log.string, "truncated"
  end

  def test_skips_invalid_plan_entries
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)
    long_name = "a" * (HireFire::Lease::MAX_NAME_BYTES + 1)

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

  def test_sample_if_due_advances_next_sample_at
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "10"
      })

    lease.request_if_due(hold: ->(_) { true })
    lease.sample_if_due {}

    expected = Time.now + 10
    actual = lease.instance_variable_get(:@next_sample_at)
    assert_in_delta expected.to_f, actual.to_f, 1
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

  def test_clamps_a_garbled_sample_frequency_to_a_sane_floor
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "0"
      })

    lease.request_if_due(hold: ->(_) { true })

    assert_equal HireFire::Lease::SAMPLE_FREQUENCY_BOUNDS.begin, lease.sample_frequency
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

  def test_clamps_a_garbled_ttl_to_a_sane_floor
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Lease-TTL" => "0"
      })

    lease.request_if_due(hold: ->(_) { true })

    assert_equal HireFire::Lease::TTL_BOUNDS.begin, lease.instance_variable_get(:@ttl)
  end

  def test_clamps_an_over_large_ttl_to_the_ceiling
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Lease-TTL" => "99999"
      })

    lease.request_if_due(hold: ->(_) { true })

    assert_equal HireFire::Lease::TTL_BOUNDS.end, lease.instance_variable_get(:@ttl)
  end

  def test_closes_the_underlying_client
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {"HireFire-Lease-Granted" => "true"})

    lease.request_if_due(hold: ->(_) { true })
    lease.close

    refute lease.instance_variable_get(:@client).instance_variable_get(:@http)
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
    lease.instance_variable_set(:@expires_at, 5000.0)

    Timecop.freeze(Time.at(1000)) { lease.request_if_due(hold: ->(_) { true }) }

    assert_equal 5030.0, lease.instance_variable_get(:@expires_at)
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

    lease.instance_variable_set(:@owner_pid, lease.instance_variable_get(:@owner_pid) - 1)

    lease.request_if_due(hold: ->(_) { true })

    refute_equal original_process_id, lease.process_id
    assert_equal Process.pid, lease.instance_variable_get(:@owner_pid)
    assert_requested(:post, "https://data.hirefire.io/metrics/lease",
      headers: {"HireFire-Process-ID" => lease.process_id})
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
      assert_raises(HireFire::Client::RequestError) { lease.request_if_due(hold: ->(_) { true }) }
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
      lease = HireFire::Lease.new
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
end
