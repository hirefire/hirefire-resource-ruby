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
      # X-Queue-Start is an exact synonym (e.g. Render emits it).
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
      # Both present: X-Request-Start (1000ms) wins over X-Queue-Start (5000ms).
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

  def test_parses_nanoseconds_format
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"
    HireFire::Dispatcher.any_instance.stubs(:start)

    HireFire.configure do |config|
      config.dyno(:web)
    end

    Timecop.freeze Time.at(1_700_000_001) do
      request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => "1700000000000000000")
      @middleware.call(request)

      data = HireFire.configuration.buffer.flush
      assert_equal({1_700_000_001 => [1000]}, data[:web])
    end
  end

  def test_normalizes_every_precision_variant_to_the_same_queue_time
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"
    HireFire::Dispatcher.any_instance.stubs(:start)

    HireFire.configure do |config|
      config.dyno(:web)
    end

    # The same instant in every unit a router may emit, all normalizing to 750ms.
    # The 250ms fraction tests the sub-ms path, including ns (beyond a double's exact int range).
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
      # Future start in microseconds: clamp-to-zero is applied after unit inference.
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
      # ~1000s in the past in nanoseconds: the 60s cap drops it regardless of unit.
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
      # Exactly 1e9 is a valid epoch-seconds timestamp (2001-09-09), not rejected.
      request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => "1000000000")
      @middleware.call(request)
      assert_equal({1_000_000_001 => [1000]}, HireFire.configuration.buffer.flush[:web])

      # One below the 1e9 guard is implausible and dropped.
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
      # Future start (router clock skew) => negative queue time must clamp to 0.
      request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => "1700000005000")
      @middleware.call(request)

      assert_equal({1_700_000_001 => [0]}, HireFire.configuration.buffer.flush[:web])
    end
  end

  def test_keeps_a_high_but_plausible_queue_time
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"
    HireFire::Dispatcher.any_instance.stubs(:start)

    HireFire.configure do |config|
      config.dyno(:web)
    end

    Timecop.freeze Time.at(1_700_000_000) do
      # 50s: severe overload but under the limit, so still reported.
      request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => "1699999950000")
      @middleware.call(request)

      assert_equal({1_700_000_000 => [50_000]}, HireFire.configuration.buffer.flush[:web])
    end
  end

  def test_drops_an_over_the_limit_queue_time
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"
    HireFire::Dispatcher.any_instance.stubs(:start)

    HireFire.configure do |config|
      config.dyno(:web)
    end

    Timecop.freeze Time.at(1_700_000_000) do
      # ~16 min of queue time, over the 60-second cap.
      request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => "1699999000000")
      @middleware.call(request)

      assert_empty HireFire.configuration.buffer.flush[:web]
    end
  end

  def test_cap_boundary_keeps_exactly_the_limit_and_drops_one_over
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"
    HireFire::Dispatcher.any_instance.stubs(:start)

    HireFire.configure do |config|
      config.dyno(:web)
    end

    Timecop.freeze Time.at(1_700_000_000) do
      # Exactly 60_000ms: at the inclusive limit, so kept.
      request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => "1699999940000")
      @middleware.call(request)
      assert_equal({1_700_000_000 => [60_000]}, HireFire.configuration.buffer.flush[:web])

      # 60_001ms: one over the limit, so dropped.
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

  def test_an_internal_failure_does_not_break_the_request
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"

    HireFire.configure do |config|
      config.dyno(:web)
    end
    HireFire.configuration.logger = Logger.new(log)

    # An internal failure (here a refused thread in start) must be swallowed, not raised.
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

    # The guard wraps only the bookkeeping, never @app.call, so host errors propagate.
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
