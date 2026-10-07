# frozen_string_literal: true

require "test_helper"

class LeaseHeaderGarbageEvidence < Minitest::Test
  def test_a_non_numeric_sample_frequency_keeps_the_current_value
    ENV["HIREFIRE_TOKEN"] = "token"
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {"HireFire-Lease-Granted" => "false", "HireFire-Sample-Frequency" => "soon"})

    lease = HireFire::Lease.new
    before = lease.sample_frequency
    lease.request_if_due(hold: ->(_entries) { true })

    assert_equal before, lease.sample_frequency
  end
end
