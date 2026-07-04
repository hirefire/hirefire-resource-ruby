# frozen_string_literal: true

require "test_helper"
require "rack/mock"

class HireFire::MiddlewareTest < Minitest::Test
  def log
    @log ||= StringIO.new
  end

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

  def test_reads_x_queue_start_when_request_start_is_absent
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"
    HireFire::Dispatcher.any_instance.stubs(:start)

    HireFire.configure do |config|
      config.dyno(:web)
    end

    Timecop.freeze Time.at(1_700_000_001) do
      request = Rack::MockRequest.env_for("/", "HTTP_X_QUEUE_START" => "1700000000000")
      @middleware.call(request)

      assert_equal({1_700_000_001 => [1000]}, HireFire.configuration.buffer.flush[:web])
    end
  end

  def test_prefers_x_request_start_over_x_queue_start
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"
    HireFire::Dispatcher.any_instance.stubs(:start)

    HireFire.configure do |config|
      config.dyno(:web)
    end

    Timecop.freeze Time.at(1_700_000_001) do
      request = Rack::MockRequest.env_for("/",
        "HTTP_X_REQUEST_START" => "1700000000000",
        "HTTP_X_QUEUE_START" => "1699999996000")
      @middleware.call(request)

      assert_equal({1_700_000_001 => [1000]}, HireFire.configuration.buffer.flush[:web])
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

  def test_normalizes_every_precision_variant_to_the_same_queue_time
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"
    HireFire::Dispatcher.any_instance.stubs(:start)

    HireFire.configure do |config|
      config.dyno(:web)
    end

    {
      seconds: "t=1700000000.250",
      milliseconds: "1700000000250",
      microseconds: "1700000000250000",
      nanoseconds: "1700000000250000000"
    }.each do |unit, header|
      Timecop.freeze Time.at(1_700_000_001) do
        request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => header)
        @middleware.call(request)

        assert_equal({1_700_000_001 => [750]}, HireFire.configuration.buffer.flush[:web],
          "#{unit} variant should normalize to 750ms")
      end
    end
  end

  def test_clamps_a_future_microsecond_start_to_zero
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"
    HireFire::Dispatcher.any_instance.stubs(:start)

    HireFire.configure do |config|
      config.dyno(:web)
    end

    Timecop.freeze Time.at(1_700_000_001) do
      request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => "1700000005000000")
      @middleware.call(request)

      assert_equal({1_700_000_001 => [0]}, HireFire.configuration.buffer.flush[:web])
    end
  end

  def test_drops_an_over_the_limit_nanosecond_start
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"
    HireFire::Dispatcher.any_instance.stubs(:start)

    HireFire.configure do |config|
      config.dyno(:web)
    end

    Timecop.freeze Time.at(1_700_000_000) do
      request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => "1699999000000000000")
      @middleware.call(request)

      assert_empty HireFire.configuration.buffer.flush[:web]
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

  def test_lower_guard_boundary_accepts_1e9_and_rejects_below
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"
    HireFire::Dispatcher.any_instance.stubs(:start)

    HireFire.configure do |config|
      config.dyno(:web)
    end

    Timecop.freeze Time.at(1_000_000_001) do
      request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => "1000000000")
      @middleware.call(request)
      assert_equal({1_000_000_001 => [1000]}, HireFire.configuration.buffer.flush[:web])

      request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => "999999999")
      @middleware.call(request)
      assert_empty HireFire.configuration.buffer.flush[:web]
    end
  end

  def test_clamps_a_future_request_start_to_zero
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"
    HireFire::Dispatcher.any_instance.stubs(:start)

    HireFire.configure do |config|
      config.dyno(:web)
    end

    Timecop.freeze Time.at(1_700_000_001) do
      request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => "1700000005000")
      @middleware.call(request)

      assert_equal({1_700_000_001 => [0]}, HireFire.configuration.buffer.flush[:web])
    end
  end

  def test_cap_boundary_keeps_exactly_the_limit_and_drops_one_over
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"
    HireFire::Dispatcher.any_instance.stubs(:start)

    HireFire.configure do |config|
      config.dyno(:web)
    end

    Timecop.freeze Time.at(1_700_000_000) do
      request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => "1699999940000")
      @middleware.call(request)
      assert_equal({1_700_000_000 => [60_000]}, HireFire.configuration.buffer.flush[:web])

      request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => "1699999939999")
      @middleware.call(request)
      assert_empty HireFire.configuration.buffer.flush[:web]
    end
  end

  def test_no_request_start_header_is_a_noop
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"
    HireFire::Dispatcher.any_instance.stubs(:start)

    HireFire.configure do |config|
      config.dyno(:web)
    end

    response = @request.get("/")
    assert_equal 200, response.status
    assert_empty HireFire.configuration.buffer.flush[:web]
  end

  def test_does_not_sample_without_a_web_collector
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"

    request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => "1700000000000")
    @middleware.call(request)

    assert_empty HireFire.configuration.buffer.flush[:web]
  end

  def test_does_not_sample_without_a_token
    HireFire.configure do |config|
      config.dyno(:web)
    end

    request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => "1700000000000")
    @middleware.call(request)

    assert_empty HireFire.configuration.buffer.flush[:web]
  end

  def test_an_internal_failure_does_not_break_the_request
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"

    HireFire.configure do |config|
      config.dyno(:web)
    end
    HireFire.configuration.logger = Logger.new(log)

    HireFire.configuration.dispatcher.stubs(:start).raises(ThreadError.new("cannot create thread"))

    Timecop.freeze Time.at(1_700_000_001) do
      request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => "1700000000000")
      status, _headers, body = @middleware.call(request)

      assert_equal 200, status
      assert_equal ["Hello"], body
    end

    assert_includes log.string, "Middleware error"
  end

  def test_a_raising_logger_does_not_break_the_request
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"
    HireFire::Dispatcher.any_instance.stubs(:start)

    HireFire.configure do |config|
      config.dyno(:web)
    end

    raising_logger = Object.new
    def raising_logger.info(*)
    end

    def raising_logger.error(*)
      raise "logger blew up"
    end
    HireFire.configuration.logger = raising_logger

    HireFire.configuration.web.stubs(:sample).raises("sampling blew up")

    Timecop.freeze Time.at(1_700_000_001) do
      request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => "1700000000000")
      status, _headers, body = @middleware.call(request)

      assert_equal 200, status
      assert_equal ["Hello"], body
    end
  end

  def test_an_error_raised_by_the_host_app_still_propagates
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"
    HireFire::Dispatcher.any_instance.stubs(:start)

    HireFire.configure do |config|
      config.dyno(:web)
    end

    middleware = HireFire::Middleware.new(proc { |_| raise "boom from the app" })

    Timecop.freeze Time.at(1_700_000_001) do
      request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => "1700000000000")
      error = assert_raises(RuntimeError) { middleware.call(request) }
      assert_equal "boom from the app", error.message
    end
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
