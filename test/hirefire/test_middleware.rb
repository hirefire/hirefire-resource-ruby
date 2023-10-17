# frozen_string_literal: true

require "test_helper"
require "rack/mock"

class HireFire::MiddlewareTest < Minitest::Test
  def setup
    @app = proc { |_| [200, {}, ["Hello"]] }
    @middleware = HireFire::Middleware.new(@app)
    @request = Rack::MockRequest.new(@middleware)
  end

  def test_info_path_for_development
    HireFire::Resource.configure do |config|
      config.dyno(:worker) { 5 }
    end

    response = @request.get("/hirefire/development/info")
    expected_body = [{name: "worker", value: 5}].to_json
    assert_equal 200, response.status
    assert_equal expected_body, response.body
  end

  def test_info_path_for_token
    ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"

    HireFire::Resource.configure do |config|
      config.dyno(:worker) { 5 }
    end

    response = @request.get("/hirefire/SOME_TOKEN/info")
    expected_body = [{name: "worker", value: 5}].to_json
    assert_equal 200, response.status
    assert_equal expected_body, response.body
  end

  def test_non_intercepted_path
    response = @request.get("/some/other/path")
    assert_equal 200, response.status
    assert_equal "Hello", response.body
  end

  def test_process_request_queue_time_with_dyno_web
    HireFire::Resource.configure do |config|
      config.dyno(:web)
    end

    HireFire::Resource.configuration.web.stub(:start, nil) do
      Time.stub :now, Time.at(1) do
        request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => 0)
        @middleware.call(request)
        assert_equal ({1 => [1000]}), HireFire::Resource.configuration.web.flush
      end
    end
  end

  def test_process_request_queue_time_with_log_queue_metrics
    HireFire::Resource.configure do |config|
      config.log_queue_metrics = true
    end

    Time.stub :now, Time.at(1) do
      request = Rack::MockRequest.env_for("/", "HTTP_X_REQUEST_START" => 0)
      stdout = capture { @middleware.call(request) }
      assert_includes stdout, "[hirefire:router] queue=1000ms"
    end
  end
end
