# frozen_string_literal: true

require "test_helper"
require "rack/mock"

class HireFire::MiddlewareTest < Minitest::Test
  def setup
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

    Time.stub :now, Time.at(1) do
      request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => 0)
      @middleware.call(request)

      data = HireFire.configuration.buffer.flush
      assert_equal({1 => [1000]}, data[:web])
    end
  end

  def test_starts_dispatcher_on_web_request
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"

    HireFire.configure do |config|
      config.dyno(:web)
    end

    HireFire.configuration.dispatcher.expects(:start).once

    Time.stub :now, Time.at(1) do
      request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => 0)
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
    original_stdout = $stdout
    $stdout = StringIO.new

    Time.stub :now, Time.at(1) do
      request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => 0)
      @middleware.call(request)
    end

    assert_empty $stdout.string
  ensure
    $stdout = original_stdout
  end

  def test_pass_through_and_process_log_queue_metrics
    original_stdout = $stdout
    $stdout = StringIO.new

    HireFire.configure do |config|
      config.log_queue_metrics = true
    end

    Time.stub :now, Time.at(1) do
      request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => 0)
      @middleware.call(request)
    end

    assert_equal("[hirefire:router] queue=1000ms", $stdout.string.strip)
  ensure
    $stdout = original_stdout
  end
end
