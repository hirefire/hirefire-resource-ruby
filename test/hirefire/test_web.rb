# frozen_string_literal: true

require "test_helper"

class HireFire::WebTest < Minitest::Test
  def web
    @web ||= HireFire::Web.new
  end

  def log
    @log ||= StringIO.new
  end

  def setup
    ENV["HIREFIRE_TOKEN"] = "8ab101e2-51da-49bc-beba-111dec49a287"
    WebMock.reset_executed_requests!
    HireFire.configuration.logger = Logger.new(log)
  end

  def test_starts_and_stops_correctly
    refute web.dispatcher_running?
    assert web.start_dispatcher
    assert web.dispatcher_running?
    refute web.start_dispatcher
    web.add_to_buffer(1)
    assert web.stop_dispatcher
    refute web.dispatcher_running?
    refute web.stop_dispatcher
    assert_empty web.send :flush_buffer
    assert_includes log.string, "[HireFire] Starting web metrics dispatcher."
    assert_includes log.string, "[HireFire] Web metrics dispatcher stopped."
  end

  def test_buffer_addition
    web.add_to_buffer(1)
    buffer_contents = web.send :flush_buffer
    refute_empty buffer_contents
    assert_equal [1], buffer_contents.values.first
  end

  def test_buffer_flushing
    web.add_to_buffer(2)
    web.send :flush_buffer
    buffer_contents_after_flush = web.send :flush_buffer
    assert_empty buffer_contents_after_flush
  end

  def test_successful_dispatch_post
    request = stub_request(:post, "https://logdrain.hirefire.io/")
      .with(headers: {"HireFire-Resource" => "Ruby-#{HireFire::VERSION}"})
      .to_return(status: 200)
    web.add_to_buffer(5)
    web.send :dispatch_buffer
    assert log.string.empty?
    assert_requested request
  end

  def test_dispatch_post_with_unexpected_response_code
    stub_request(:post, "https://logdrain.hirefire.io/").to_return(status: 404)
    web.add_to_buffer(5)
    web.send :dispatch_buffer
    assert_includes log.string,
      "[HireFire] Error while dispatching web metrics: " \
      "An unexpected error occurred (Unexpected response code 404.)."
  end

  def test_dispatch_post_with_generic_exception
    stub_request(:post, "https://logdrain.hirefire.io/")
      .to_raise(StandardError.new("Some generic error"))
    web.add_to_buffer(8)
    web.send :dispatch_buffer
    assert_includes log.string,
      "[HireFire] Error while dispatching web metrics: " \
      "An unexpected error occurred (Some generic error)."
  end

  def test_dispatch_post_with_server_error
    stub_request(:post, "https://logdrain.hirefire.io/").to_return(status: 500)
    web.add_to_buffer(4)
    web.send :dispatch_buffer
    assert_includes log.string,
      "[HireFire] Error while dispatching web metrics: " \
      "An unexpected error occurred (Server responded with 500 status.)."
  end

  def test_dispatch_post_with_timeout
    stub_request(:post, "https://logdrain.hirefire.io/").to_timeout
    web.add_to_buffer(5)
    web.send :dispatch_buffer
    assert_includes log.string,
      "[HireFire] Error while dispatching web metrics: " \
      "Request timed out."
  end

  def test_dispatch_post_with_network_error
    stub_request(:post, "https://logdrain.hirefire.io/").to_raise(SocketError.new("Failed"))
    web.add_to_buffer(6)
    web.send :dispatch_buffer
    assert_includes log.string,
      "[HireFire] Error while dispatching web metrics: " \
      "Network error occurred (Failed)."
  end

  def test_buffer_repopulation_after_dispatch_failure
    stub_request(:post, "https://logdrain.hirefire.io/").to_return(status: 500)
    web.add_to_buffer(7)
    web.send :dispatch_buffer
    buffer_contents_after_fail = web.send :flush_buffer
    assert_equal [7], buffer_contents_after_fail.values.first
  end

  def test_buffer_ttl_discards_old_entries
    stub_request(:post, "https://logdrain.hirefire.io/").to_return(status: 500)
    web.add_to_buffer(7)
    past_timestamp = Time.now.to_i - HireFire::Web::BUFFER_TTL - 10
    Time.stub(:now, Time.at(past_timestamp)) do
      web.add_to_buffer(8)
    end
    web.send :dispatch_buffer
    buffer_contents_after_fail = web.send :flush_buffer
    assert_equal [7], buffer_contents_after_fail.values.first
    assert_nil buffer_contents_after_fail[past_timestamp]
  end
end
