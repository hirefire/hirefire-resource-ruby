# frozen_string_literal: true

require "test_helper"
require "sinatra/base"
require "rack/mock"

module HireFire
  module Integration
    class SinatraTest < Minitest::Test
      class Application < Sinatra::Base
        set :environment, :test

        get "/" do
          "Hello"
        end
      end

      APP = Rack::Builder.new do
        use HireFire::Middleware
        run Application
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
          assert_equal({1_700_000_001 => [1000]}, HireFire.configuration.buffer.flush[:web])
        end
      end

      def test_reads_x_queue_start_when_request_start_is_absent
        configure_web

        Timecop.freeze Time.at(1_700_000_001) do
          Rack::MockRequest.new(app).get("/", "HTTP_X_QUEUE_START" => "1700000000000")
          assert_equal({1_700_000_001 => [1000]}, HireFire.configuration.buffer.flush[:web])
        end
      end

      private

      def configure_web
        HireFire.configure { |config| config.dyno(:web) }
        HireFire.configuration.dispatcher.stubs(:start)
        ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"
      end
    end
  end
end
