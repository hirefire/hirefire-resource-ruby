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

    HireFire.configuration.web.expects(:start_dispatcher).never

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

  def test_intercept_and_process_worker_configuration
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"

    HireFire.configure do |config|
      config.dyno(:worker) { 5 }
    end

    response = @request.get("/hirefire/SOME_TOKEN/info")
    expected_body = [{name: "worker", value: 5}].to_json
    assert_equal 200, response.status
    assert_equal "Ruby-#{HireFire::VERSION}", response.headers["HireFire-Resource"]
    assert_equal expected_body, response.body
  end

  def test_pass_through_and_process_web_configuration
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"

    HireFire.configure do |config|
      config.dyno(:web)
    end

    HireFire.configuration.web.stub(:start_dispatcher, nil) do
      Time.stub :now, Time.at(1) do
        request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => 0)
        @middleware.call(request)
        assert_equal ({1 => [1000]}), HireFire.configuration.web.flush_buffer
      end
    end
  end

  def test_pass_through_and_process_logplex_configuration
    HireFire.configure do |config|
      config.log_queue_metrics = true
    end

    Time.stub :now, Time.at(1) do
      request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => 0)
      stdout = capture { @middleware.call(request) }
      assert_includes stdout, "[hirefire:router] queue=1000ms"
    end
  end
end
