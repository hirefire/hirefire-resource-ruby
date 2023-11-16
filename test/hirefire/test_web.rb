# frozen_string_literal: true

require "test_helper"

class HireFire::WebTest < Minitest::Test
  def setup
    HireFire.configuration.logger = Logger.new("/dev/null")
    ENV["HIREFIRE_TOKEN"] = "8ab101e2-51da-49bc-beba-111dec49a287"
    WebMock.reset_executed_requests!
  end

  def test_starts_and_stops_correctly
    web = HireFire::Web.new
    refute web.running?
    web.start
    assert web.running?
    web.add_to_buffer(1)
    web.stop
    assert_empty web.flush
    refute web.running?
  end

  def test_buffer_addition
    web = HireFire::Web.new
    web.add_to_buffer(1)
    buffer_contents = web.flush
    refute_empty buffer_contents
    assert_equal [1], buffer_contents.values.first
  end

  def test_buffer_flushing
    web = HireFire::Web.new
    web.add_to_buffer(2)
    web.flush
    buffer_contents_after_flush = web.flush
    assert_empty buffer_contents_after_flush
  end

  def test_successful_dispatch_post
    web = HireFire::Web.new
    request = stub_request(:post, "https://logdrain.hirefire.io/")
      .with(headers: {"HireFire-Resource" => "Ruby-#{HireFire::VERSION}"})
      .to_return(status: 200)
    web.add_to_buffer(5)

    log_output = StringIO.new
    HireFire.configuration.logger = Logger.new(log_output)
    web.dispatch

    assert log_output.string.empty?
    assert_requested request
  end

  def test_dispatch_post_with_unexpected_response_code
    web = HireFire::Web.new
    stub_request(:post, "https://logdrain.hirefire.io/").to_return(status: 404)
    web.add_to_buffer(5)

    log_output = StringIO.new
    HireFire.configuration.logger = Logger.new(log_output)
    web.dispatch

    assert_includes log_output.string,
      "[HireFire] Error while dispatching web metrics: " \
      "An unexpected error occurred (Unexpected response code 404.).\n"
  end

  def test_dispatch_post_with_generic_exception
    web = HireFire::Web.new
    stub_request(:post, "https://logdrain.hirefire.io/").to_raise(StandardError.new("Some generic error"))
    web.add_to_buffer(8)

    log_output = StringIO.new
    HireFire.configuration.logger = Logger.new(log_output)
    web.dispatch

    assert_includes log_output.string,
      "[HireFire] Error while dispatching web metrics: An unexpected error occurred (Some generic error)."
  end

  def test_dispatch_post_with_server_error
    web = HireFire::Web.new
    stub_request(:post, "https://logdrain.hirefire.io/").to_return(status: 500)
    web.add_to_buffer(4)

    log_output = StringIO.new
    HireFire.configuration.logger = Logger.new(log_output)
    web.dispatch

    assert_includes log_output.string,
      "[HireFire] Error while dispatching web metrics: " \
      "An unexpected error occurred (Server responded with 500 status.)."
  end

  def test_dispatch_post_with_timeout
    web = HireFire::Web.new
    stub_request(:post, "https://logdrain.hirefire.io/").to_timeout
    web.add_to_buffer(5)

    log_output = StringIO.new
    HireFire.configuration.logger = Logger.new(log_output)
    web.dispatch

    assert_includes log_output.string,
      "[HireFire] Error while dispatching web metrics: Request timed out."
  end

  def test_dispatch_post_with_network_error
    web = HireFire::Web.new
    stub_request(:post, "https://logdrain.hirefire.io/").to_raise(SocketError.new("Failed"))
    web.add_to_buffer(6)

    log_output = StringIO.new
    HireFire.configuration.logger = Logger.new(log_output)
    web.dispatch

    assert_includes log_output.string,
      "[HireFire] Error while dispatching web metrics: Network error occurred (Failed)."
  end

  def test_buffer_repopulation_after_dispatch_failure
    web = HireFire::Web.new
    stub_request(:post, "https://logdrain.hirefire.io/").to_return(status: 500)

    web.add_to_buffer(7)
    web.dispatch

    buffer_contents_after_fail = web.flush
    assert_equal [7], buffer_contents_after_fail.values.first
  end

  def test_buffer_ttl_discards_old_entries
    web = HireFire::Web.new
    stub_request(:post, "https://logdrain.hirefire.io/").to_return(status: 500)

    web.add_to_buffer(7)

    past_timestamp = Time.now.to_i - HireFire::Web::BUFFER_TTL - 10
    Time.stub(:now, Time.at(past_timestamp)) do
      web.add_to_buffer(8)
    end

    web.dispatch
    buffer_contents_after_fail = web.flush

    assert_equal [7], buffer_contents_after_fail.values.first
    assert_nil buffer_contents_after_fail[past_timestamp]
  end
end
