# frozen_string_literal: true

require "test_helper"
require "rack/mock"

class HireFire::MiddlewareTest < Minitest::Test
  def setup
    super
    @app = proc { |_| [200, {}, ["Hello"]] }
    @middleware = HireFire::Middleware.new(@app)
    @request = Rack::MockRequest.new(@middleware)
  end

  def test_pass_through_without_HIREFIRE_TOKEN
    HireFire.configure do |config|
      config.dyno(:web)
    end

    response = @request.get("/")
    assert_equal 200, response.status
    assert_equal "Hello", response.body
  end

  def test_pass_through_without_configuration
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"

    response = @request.get("/")
    assert_equal 200, response.status
    assert_equal "Hello", response.body
  end

  def test_collects_web_sample
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"

    HireFire.configure do |config|
      config.dyno(:web)
    end

    HireFire.configuration.dispatcher.stubs(:start)

    Timecop.freeze Time.at(1_700_000_001) do
      request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => "1700000000000")
      @middleware.call(request)

      data = HireFire.configuration.buffer.flush
      assert_equal({1_700_000_001 => [1000]}, data[:web])
    end
  end

  def test_starts_dispatcher_on_web_request
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"

    HireFire.configure do |config|
      config.dyno(:web)
    end

    HireFire.configuration.dispatcher.expects(:start).once

    Timecop.freeze Time.at(1_700_000_001) do
      request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => "1700000000000")
      @middleware.call(request)
    end
  end

  def test_does_not_start_dispatcher_without_token
    HireFire.configure do |config|
      config.dyno(:web)
    end

    HireFire::Dispatcher.any_instance.expects(:start).never

    request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => 0)
    @middleware.call(request)
  end

  def test_pass_through_without_log_queue_metrics
    output = capture do
      Timecop.freeze Time.at(1) do
        request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => 0)
        @middleware.call(request)
      end
    end

    assert_empty output
  end

  def test_pass_through_and_process_log_queue_metrics
    HireFire.configure do |config|
      config.log_queue_metrics = true
    end

    output = capture do
      Timecop.freeze Time.at(1_700_000_001) do
        request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => "1700000000000")
        @middleware.call(request)
      end
    end

    assert_equal("[hirefire:router] queue=1000ms", output.strip)
  end

  def test_parses_nginx_seconds_format
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"
    HireFire::Dispatcher.any_instance.stubs(:start)

    HireFire.configure do |config|
      config.dyno(:web)
    end

    Timecop.freeze Time.at(1_700_000_001) do
      request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => "t=1700000000.000")
      @middleware.call(request)

      data = HireFire.configuration.buffer.flush
      assert_equal({1_700_000_001 => [1000]}, data[:web])
    end
  end

  def test_parses_apache_microseconds_format
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"
    HireFire::Dispatcher.any_instance.stubs(:start)

    HireFire.configure do |config|
      config.dyno(:web)
    end

    Timecop.freeze Time.at(1_700_000_001) do
      request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => "t=1700000000000000")
      @middleware.call(request)

      data = HireFire.configuration.buffer.flush
      assert_equal({1_700_000_001 => [1000]}, data[:web])
    end
  end

  def test_ignores_unparseable_request_start
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"
    HireFire::Dispatcher.any_instance.stubs(:start)

    HireFire.configure do |config|
      config.dyno(:web)
    end

    request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => "garbage")
    @middleware.call(request)

    assert_empty HireFire.configuration.buffer.flush[:web]
  end

  def test_ignores_implausible_request_start
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"
    HireFire::Dispatcher.any_instance.stubs(:start)

    HireFire.configure do |config|
      config.dyno(:web)
    end

    request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => "t=0.05")
    @middleware.call(request)

    assert_empty HireFire.configuration.buffer.flush[:web]
  end

  def test_clamps_a_future_request_start_to_zero
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"
    HireFire::Dispatcher.any_instance.stubs(:start)

    HireFire.configure do |config|
      config.dyno(:web)
    end

    Timecop.freeze Time.at(1_700_000_001) do
      # Future start (router clock skew) => negative queue time must clamp to 0.
      request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => "1700000005000")
      @middleware.call(request)

      assert_equal({1_700_000_001 => [0]}, HireFire.configuration.buffer.flush[:web])
    end
  end

  def test_no_request_start_header_is_a_noop
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"
    HireFire::Dispatcher.any_instance.stubs(:start)

    HireFire.configure do |config|
      config.dyno(:web)
    end

    response = @request.get("/") # no HTTP_X_REQUEST_START header
    assert_equal 200, response.status
    assert_empty HireFire.configuration.buffer.flush[:web]
  end

  def test_does_not_sample_without_a_web_collector
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN" # token present, but no config.dyno(:web)

    request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => "1700000000000")
    @middleware.call(request)

    assert_empty HireFire.configuration.buffer.flush[:web]
  end

  def test_does_not_sample_without_a_token
    HireFire.configure do |config|
      config.dyno(:web) # web present, but no HIREFIRE_TOKEN
    end

    request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => "1700000000000")
    @middleware.call(request)

    assert_empty HireFire.configuration.buffer.flush[:web]
  end

  def test_returns_the_apps_response_on_the_sampling_path
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"
    HireFire::Dispatcher.any_instance.stubs(:start)

    HireFire.configure do |config|
      config.dyno(:web)
    end

    Timecop.freeze Time.at(1_700_000_001) do
      request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => "1700000000000")
      status, headers, body = @middleware.call(request)

      assert_equal 200, status
      assert_equal({}, headers)
      assert_equal ["Hello"], body
    end
  end
end
