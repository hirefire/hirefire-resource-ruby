# frozen_string_literal: true

require "test_helper"
require "stringio"

class LeaseTruncationMessageEvidence < Minitest::Test
  def test_truncation_message_does_not_call_valid_entries_invalid
    ENV["HIREFIRE_TOKEN"] = "token"
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)
    entries = Array.new(300) { |index| {"name" => "queue-#{index}", "strategy" => "jqs"} }
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {"HireFire-Lease-Granted" => "true"}, body: JSON.generate("job_queues" => entries))

    lease = HireFire::Lease.new
    lease.request_if_due(hold: ->(_entries) { true })

    assert_equal 256, lease.job_queues.size
    assert_match(/truncated to 256/, log.string)
    refute_match(/invalid also skipped/, log.string)
  end
end
