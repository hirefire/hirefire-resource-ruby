# frozen_string_literal: true

require "test_helper"
require "rails"
require "action_controller/railtie"
require "rack/mock"
require "tmpdir"
require "open3"
require "rbconfig"
require "timeout"

module HireFire
  module Integration
    class RailsTest < Minitest::Test
      class Application < Rails::Application
        config.load_defaults "#{Rails::VERSION::MAJOR}.#{Rails::VERSION::MINOR}"
        config.eager_load = false
        config.secret_key_base = "test_secret_key_base"
        config.logger = Logger.new(File::NULL)
        config.hosts.clear
      end

      Application.initialize!
      Application.routes.draw do
        get "/", to: ->(_env) { [200, {}, ["Hello"]] }
      end

      def app
        Application
      end

      def test_railtie_inserts_middleware_at_the_front_of_the_stack
        assert_equal HireFire::Middleware, app.middleware.first.klass
      end

      # Initializer blocks run on the railtie *instance*. Helpers must be instance
      # methods (not class methods) or every Rails boot raises NoMethodError
      # (worker dynos load config/environment and hit the same path).
      def test_middleware_already_queued_is_callable_from_railtie_instance
        railtie = HireFire::Railtie.instance
        assert railtie.respond_to?(:middleware_already_queued?, true)
        refute HireFire::Railtie.respond_to?(:middleware_already_queued?)
        assert_equal true, railtie.send(:middleware_already_queued?, app)
      end

      def test_railtie_is_loaded_for_boot_on_token
        assert defined?(HireFire::Railtie)
        assert HireFire::Railtie < ::Rails::Railtie
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

      # Fresh Rails app process: token present before initialize! so the railtie
      # after_initialize path boots (not a manual HireFire.boot after init).
      def test_railtie_after_initialize_auto_boots_when_token_set_before_init
        Dir.mktmpdir("hirefire-railtie-boot") do |dir|
          marker = File.join(dir, "booted")
          script = File.join(dir, "boot_app.rb")
          lib = File.expand_path("../../../lib", __dir__)
          defaults = "#{Rails::VERSION::MAJOR}.#{Rails::VERSION::MINOR}"

          File.write(script, <<~RUBY)
            # frozen_string_literal: true
            require "bundler/setup"
            require "rails"
            require "action_controller/railtie"
            $LOAD_PATH.unshift #{lib.inspect}
            require "hirefire-resource"
            require "logger"

            ENV["HIREFIRE_TOKEN"] = "railtie-auto-boot-token"
            ENV["DYNO"] = "web.1"

            HireFire::Dispatcher.class_eval do
              def start
                File.write(#{marker.inspect}, "started")
                true
              end

              def ensure_job_queue_loop
              end
            end

            class RailtieBootApp < Rails::Application
              config.load_defaults #{defaults.inspect}
              config.eager_load = false
              config.secret_key_base = "test_secret_key_base_for_railtie_boot"
              config.logger = Logger.new(File::NULL)
              config.hosts.clear
            end

            RailtieBootApp.initialize!
            exit(File.file?(#{marker.inspect}) ? 0 : 1)
          RUBY

          env = {
            "BUNDLE_GEMFILE" => ENV.fetch("BUNDLE_GEMFILE"),
            "PATH" => ENV["PATH"],
            "HOME" => ENV["HOME"],
            "TMPDIR" => ENV["TMPDIR"],
            "GEM_HOME" => ENV["GEM_HOME"],
            "GEM_PATH" => ENV["GEM_PATH"],
            "RUBYLIB" => ENV["RUBYLIB"],
            "RBENV_VERSION" => ENV["RBENV_VERSION"],
            "MISE_RUBY_VERSION" => ENV["MISE_RUBY_VERSION"],
            "HIREFIRE_TOKEN" => "railtie-auto-boot-token",
            "DYNO" => "web.1"
          }.compact

          stdout = stderr = status = nil
          Timeout.timeout(30) do
            stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, script)
          end

          assert status.success?, "railtie auto-boot subprocess failed (#{status}):\n#{stdout}\n#{stderr}"
          assert_equal "started", File.read(marker)
        rescue Timeout::Error
          flunk "railtie auto-boot subprocess timed out after 30s\n#{stdout}\n#{stderr}"
        end
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
        HireFire.configure { |config| config.dyno(:web) }
      end
    end
  end
end
