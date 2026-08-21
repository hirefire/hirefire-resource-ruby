# frozen_string_literal: true

require "test_helper"
require "hanami/router"
require "rack/mock"

module HireFire
  module Integration
    class HanamiTest < Minitest::Test
      ROUTER = Hanami::Router.new do
        get "/", to: ->(_env) { [200, {}, ["Hello"]] }
      end

      APP = Rack::Builder.new do
        use HireFire::Middleware
        run ROUTER
      end.to_app

      def app
        APP
      end

      def test_collects_web_sample_through_a_real_request
        configure_web

        Timecop.freeze Time.at(1_700_000_001) do
          response = Rack::MockRequest.new(app).get("/", "HTTP_X_REQUEST_START" => "1700000000000")
          assert_equal 200, response.status
          assert_equal "Hello", response.body
          assert_equal({1_700_000_001 => {sum: 1000.0, count: 1}}, HireFire.configuration.buffer.flush.dig("web", "rqt"))
        end
      end

      def test_zero_config_boot_starts_dispatcher_when_token_present
        HireFire::Dispatcher.any_instance.expects(:start).at_least_once
        HireFire::Dispatcher.any_instance.stubs(:ensure_job_queue_loop)
        ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"
        ENV["DYNO"] = "web.1"
        HireFire.boot
      end

      def test_zero_config_samples_via_dyno_identity
        HireFire::Dispatcher.any_instance.stubs(:start)
        HireFire::Dispatcher.any_instance.stubs(:ensure_job_queue_loop)
        ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"
        ENV["DYNO"] = "web.1"
        HireFire.boot

        Timecop.freeze Time.at(1_700_000_001) do
          response = Rack::MockRequest.new(app).get("/", "HTTP_X_REQUEST_START" => "1700000000000")
          assert_equal 200, response.status
          assert_equal({1_700_000_001 => {sum: 1000.0, count: 1}}, HireFire.configuration.buffer.flush.dig("web", "rqt"))
        end
      end

      def test_pass_through_without_token_does_not_sample
        HireFire.configure { |config| config.dyno(:web) }

        Timecop.freeze Time.at(1_700_000_001) do
          response = Rack::MockRequest.new(app).get("/", "HTTP_X_REQUEST_START" => "1700000000000")
          assert_equal 200, response.status
          assert_empty HireFire.configuration.buffer.flush
        end
      end

      private

      def configure_web
        HireFire::Dispatcher.any_instance.stubs(:start)
        HireFire::Dispatcher.any_instance.stubs(:ensure_job_queue_loop)
        ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"
        ENV["DYNO"] = "web.1"
        HireFire.configure { |config| config.dyno(:web) }
      end
    end
  end
end
