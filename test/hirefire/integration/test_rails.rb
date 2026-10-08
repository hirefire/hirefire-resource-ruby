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
        ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"
        ENV["DYNO"] = "web.1"
        HireFire.boot
      end

      def test_railtie_boots_and_takes_the_rails_logger_in_a_web_dyno
        assert_equal "started with the Rails logger", railtie_boot("DYNO" => "web.1")
      end

      def test_railtie_boots_in_a_worker_dyno
        assert_equal "started with the Rails logger", railtie_boot("DYNO" => "worker.2")
      end

      def test_railtie_boots_under_an_explicit_service_name
        assert_equal "started with the Rails logger", railtie_boot("HIREFIRE_SERVICE_NAME" => "worker")
      end

      def test_railtie_does_not_boot_without_a_token
        assert_equal "not started with the Rails logger", railtie_boot("DYNO" => "web.1", "HIREFIRE_TOKEN" => nil)
      end

      def test_railtie_does_not_boot_in_a_process_the_platform_does_not_identify
        assert_equal "not started with the Rails logger", railtie_boot({})
      end

      def test_railtie_does_not_boot_in_a_one_off_dyno
        assert_equal "not started with the Rails logger", railtie_boot("DYNO" => "run.4821")
        assert_equal "not started with the Rails logger", railtie_boot("DYNO" => "release.7310")
      end

      def test_railtie_does_not_boot_in_a_console
        assert_equal "not started with the Rails logger", railtie_boot({"DYNO" => "web.1"}, "module Rails; class Console; end; end")
      end

      def test_an_explicit_configure_starts_in_a_console_and_not_in_a_one_off_dyno
        configure = "Rails.application.config.after_initialize { HireFire.configure { |config| config.dyno(:worker) { 1 } } }"

        assert_equal "started with the Rails logger", railtie_boot({"DYNO" => "web.1"}, "module Rails; class Console; end; end", configure)
        assert_equal "not started with the Rails logger", railtie_boot({"DYNO" => "run.4821"}, "", configure)
      end

      def railtie_boot(identity, before_load = "", before_initialize = "")
        Dir.mktmpdir("hirefire-railtie-boot") do |dir|
          marker = File.join(dir, "result")
          script = File.join(dir, "boot_app.rb")
          lib = File.expand_path("../../../lib", __dir__)
          defaults = "#{Rails::VERSION::MAJOR}.#{Rails::VERSION::MINOR}"

          File.write(script, <<~RUBY)
            # frozen_string_literal: true
            require "bundler/setup"
            require "rails"
            require "action_controller/railtie"
            #{before_load}
            $LOAD_PATH.unshift #{lib.inspect}
            require "hirefire-resource"
            require "logger"

            started = false
            HireFire::Dispatcher.class_eval do
              define_method(:start) { started = true }
            end

            class RailtieBootApp < Rails::Application
              config.load_defaults #{defaults.inspect}
              config.eager_load = false
              config.secret_key_base = "test_secret_key_base_for_railtie_boot"
              config.logger = Logger.new(File::NULL)
              config.hosts.clear
            end

            #{before_initialize}
            RailtieBootApp.initialize!
            logger = HireFire.configuration.logger.equal?(::Rails.logger) ? "the Rails logger" : "its own logger"
            File.write(#{marker.inspect}, "\#{started ? "started" : "not started"} with \#{logger}")
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
            "HIREFIRE_TOKEN" => "railtie-auto-boot-token"
          }.merge(identity).compact

          stdout, stderr, status = Timeout.timeout(30) do
            Open3.capture3(env, RbConfig.ruby, script, unsetenv_others: true)
          end

          assert status.success?, "the Rails subprocess failed (#{status}):\n#{stdout}\n#{stderr}"
          File.read(marker)
        end
      end

      def test_zero_config_samples_via_dyno_identity
        HireFire::Dispatcher.any_instance.stubs(:start)
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
        ENV["HIREFIRE_TOKEN"] = "SOME_TOKEN"
        ENV["DYNO"] = "web.1"
        HireFire.configure { |config| config.dyno(:web) }
      end
    end
  end
end
