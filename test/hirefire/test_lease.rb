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

    lease.request_if_due

    assert lease.granted?
  end

  def test_denied_after_poll
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "false",
        "HireFire-Sample-Frequency" => "15"
      })

    lease.request_if_due

    refute lease.granted?
  end

  def test_updates_sample_frequency_from_response
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "false",
        "HireFire-Sample-Frequency" => "30"
      })

    lease.request_if_due

    assert_equal 30, lease.sample_frequency
  end

  def test_updates_ttl_from_response
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "false",
        "HireFire-Lease-TTL" => "30"
      })

    lease.request_if_due

    assert_equal 30, lease.instance_variable_get(:@ttl)
  end

  def test_not_polled_before_interval_elapsed
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "false",
        "HireFire-Sample-Frequency" => "15"
      })

    lease.request_if_due
    lease.request_if_due

    assert_requested(:post, "https://data.hirefire.io/metrics/lease", times: 1)
  end

  def test_silently_denied_on_unauthorized
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 401)

    lease.request_if_due

    refute lease.granted?
  end

  def test_revokes_granted_lease_on_unauthorized
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(
        {status: 200, headers: {"HireFire-Lease-Granted" => "true", "HireFire-Sample-Frequency" => "15"}},
        {status: 401}
      )

    lease.request_if_due
    assert lease.granted?

    Timecop.travel(Time.now + 15) do
      lease.request_if_due
      refute lease.granted?
    end
  end

  def test_transport_failure_demotes_and_waits_a_full_ttl
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_raise(Errno::ECONNREFUSED)

    assert_raises(HireFire::Client::RequestError) { lease.request_if_due }
    refute lease.granted?

    lease.request_if_due # not due again until the TTL elapses

    assert_requested(:post, "https://data.hirefire.io/metrics/lease", times: 1)
  end

  def test_transport_failure_revokes_granted_lease
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      })

    lease.request_if_due
    assert lease.granted?

    stub_request(:post, "https://data.hirefire.io/metrics/lease").to_timeout

    Timecop.travel(Time.now + 15) do
      assert_raises(HireFire::Client::RequestError) { lease.request_if_due }
      refute lease.granted?
    end
  end

  def test_ttl_update_applies_to_the_current_window
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Lease-TTL" => "30"
      })

    lease.request_if_due

    expected = Time.now + 30
    actual = lease.instance_variable_get(:@expires_at)
    assert_in_delta expected.to_f, actual.to_f, 1
  end

  def test_raises_on_server_error
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 500)

    error = assert_raises(HireFire::Client::RequestError) do
      lease.request_if_due
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

    lease.request_if_due

    assert_requested request
  end

  def test_disabled_lease_skips_request
    disabled = HireFire::Lease.new(enabled: false)

    disabled.request_if_due

    assert_not_requested(:post, "https://data.hirefire.io/metrics/lease")
    refute disabled.granted?
  end

  def test_sample_if_due_yields_when_granted_and_due
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      })

    lease.request_if_due
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

    lease.request_if_due
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

    lease.request_if_due
    lease.sample_if_due {} # first sample — due immediately

    sampled = false
    lease.sample_if_due { sampled = true } # second — not yet due

    refute sampled
  end

  def test_failed_sample_consumes_its_window
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      })

    lease.request_if_due

    assert_raises(RuntimeError) { lease.sample_if_due { raise "boom" } }

    sampled = false
    lease.sample_if_due { sampled = true }

    refute sampled # the raising sample consumed this window; no retry-per-tick
  end

  def test_sample_if_due_advances_next_sample_at
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "10"
      })

    lease.request_if_due
    lease.sample_if_due {}

    expected = Time.now + 10
    actual = lease.instance_variable_get(:@next_sample_at)
    assert_in_delta expected.to_f, actual.to_f, 1
  end
end
