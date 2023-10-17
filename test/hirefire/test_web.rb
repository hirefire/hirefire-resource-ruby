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
    ENV["HIREFIRE_DISPATCH_URL"] = nil
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

  def test_dispatch_with_unexpected_response_code
    stub_request(:post, "https://logdrain.hirefire.io/").to_return(status: 404)
    web.add_to_buffer(5)
    web.send :dispatch_buffer
    assert_includes log.string,
      "[HireFire] Error while dispatching web metrics: " \
      "An unexpected error occurred (Unexpected response code 404.)."
  end

  def test_dispatch_with_generic_exception
    stub_request(:post, "https://logdrain.hirefire.io/")
      .to_raise(StandardError.new("Some generic error"))
    web.add_to_buffer(8)
    web.send :dispatch_buffer
    assert_includes log.string,
      "[HireFire] Error while dispatching web metrics: " \
      "An unexpected error occurred (Some generic error)."
  end

  def test_dispatch_with_server_error
    stub_request(:post, "https://logdrain.hirefire.io/").to_return(status: 500)
    web.add_to_buffer(4)
    web.send :dispatch_buffer
    assert_includes log.string,
      "[HireFire] Error while dispatching web metrics: " \
      "An unexpected error occurred (Server responded with 500 status.)."
  end

  def test_dispatch_with_timeout
    stub_request(:post, "https://logdrain.hirefire.io/").to_timeout
    web.add_to_buffer(5)
    web.send :dispatch_buffer
    assert_includes log.string,
      "[HireFire] Error while dispatching web metrics: " \
      "Request timed out."
  end

  def test_dispatch_with_network_error
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
    buffer = web.instance_variable_get(:@buffer)
    web.send :dispatch_buffer
    assert_equal buffer, web.send(:flush_buffer)
  end

  def test_buffer_ttl_discards_old_entries
    timestamp_1 = Time.local(2000, 1, 1, 0, 0, 0).to_i
    Time.stub(:now, Time.at(timestamp_1)) do
      web.add_to_buffer(5)
      assert_equal({timestamp_1 => [5]}, web.instance_variable_get(:@buffer))
    end
    timestamp_2 = Time.local(2000, 1, 1, 0, 0, 30).to_i
    Time.stub(:now, Time.at(timestamp_2)) do
      web.add_to_buffer(10)
      assert_equal({timestamp_1 => [5], timestamp_2 => [10]}, web.instance_variable_get(:@buffer))
    end
    Time.stub(:now, Time.local(2000, 1, 1, 0, 1, 0)) do
      stub_request(:post, "https://logdrain.hirefire.io/").to_return(status: 500)
      web.send :dispatch_buffer
      assert_equal({timestamp_1 => [5], timestamp_2 => [10]}, web.instance_variable_get(:@buffer))
    end
    Time.stub(:now, Time.local(2000, 1, 1, 0, 1, 1)) do
      stub_request(:post, "https://logdrain.hirefire.io/").to_return(status: 500)
      web.send :dispatch_buffer
      assert_equal({timestamp_2 => [10]}, web.instance_variable_get(:@buffer))
    end
  end

  def test_adjust_parameters_based_on_response_headers
    stub_request(:post, "https://logdrain.hirefire.io/")
      .to_return(
        status: 200,
        headers: {
          "HireFire-Resource-Dispatch-Interval" => "10",
          "HireFire-Resource-Dispatch-Timeout" => "20",
          "HireFire-Resource-Buffer-TTL" => "30"
        }
      )
    web.add_to_buffer(5)
    web.send :dispatch_buffer
    assert_equal 10, web.instance_variable_get(:@dispatch_interval)
    assert_equal 20, web.instance_variable_get(:@dispatch_timeout)
    assert_equal 30, web.instance_variable_get(:@buffer_ttl)
  end

  def test_submit_buffer_without_token
    ENV["HIREFIRE_TOKEN"] = nil
    exception = assert_raises HireFire::Web::DispatchError do
      web.send(:submit_buffer, 5)
    end
    assert_match(/The HIREFIRE_TOKEN environment variable is not set/, exception.message)
  end

  def test_submit_buffer_with_custom_dispatcher_url
    custom_url = "https://custom.hirefire.io/"
    ENV["HIREFIRE_DISPATCH_URL"] = custom_url
    request = stub_request(:post, custom_url)
      .with(headers: {"HireFire-Resource" => "Ruby-#{HireFire::VERSION}"})
      .to_return(status: 200)
    web.add_to_buffer(5)
    web.send :dispatch_buffer
    assert_requested request
  end
end
