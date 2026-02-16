# frozen_string_literal: true

require "test_helper"

class HireFire::ConfigurationTest < Minitest::Test
  def setup
    @configuration = HireFire::Configuration.new
  end

  def test_default_logger_points_to_stdout
    assert_equal $stdout, @configuration.logger.instance_variable_get(:@logdev).dev
  end

  def test_can_set_logger
    custom_logger = Logger.new($stderr)
    @configuration.logger = custom_logger
    assert_equal custom_logger, @configuration.logger
  end

  def test_web_default_to_nil
    assert_nil @configuration.web
  end

  def test_workers_default_to_empty_array
    assert @configuration.workers.none?
  end

  def test_configure_web
    @configuration.dyno(:web)
    assert_instance_of HireFire::Web, @configuration.web
  end

  def test_configure_workers
    @configuration.dyno(:worker) { 1.23 }
    @configuration.dyno(:mailer) { 2.46 }
    workers = @configuration.workers.to_a
    assert_equal 2, workers.count
    assert_equal "worker", workers[0].name
    assert_equal 1.23, workers[0].sample
    assert_equal "mailer", workers[1].name
    assert_equal 2.46, workers[1].sample
  end

  def test_web_has_name
    @configuration.dyno(:web)
    assert_equal "web", @configuration.web.name
  end

  def test_dispatcher_returns_instance
    assert_instance_of HireFire::Dispatcher, @configuration.dispatcher
  end

  def test_dispatcher_is_memoized
    assert_same @configuration.dispatcher, @configuration.dispatcher
  end

  def test_dispatcher_receives_web
    @configuration.dyno(:web)
    d = @configuration.dispatcher
    assert_equal @configuration.web, d.instance_variable_get(:@web)
  end

  def test_dispatcher_receives_workers
    @configuration.dyno(:worker) { 1 }
    d = @configuration.dispatcher
    assert_same @configuration.workers, d.instance_variable_get(:@workers)
  end

  def test_buffer_returns_instance
    assert_instance_of HireFire::Buffer, @configuration.buffer
  end

  def test_buffer_is_memoized
    assert_same @configuration.buffer, @configuration.buffer
  end

  def test_dispatcher_without_web
    d = @configuration.dispatcher
    assert_nil d.instance_variable_get(:@web)
  end

  def test_dyno_missing_sampler_error
    assert_raises(HireFire::Configuration::MissingSamplerError) do
      @configuration.dyno(:worker)
    end
  end

  def test_log_queue_metrics_defaults_to_false
    refute @configuration.log_queue_metrics
  end

  def test_log_queue_metrics_can_be_set
    @configuration.log_queue_metrics = true
    assert @configuration.log_queue_metrics
  end

  def test_token_defaults_to_env
    ENV["HIREFIRE_TOKEN"] = "from-env"
    assert_equal "from-env", @configuration.token
  end

  def test_token_can_be_overridden
    ENV["HIREFIRE_TOKEN"] = "from-env"
    @configuration.token = "custom-token"
    assert_equal "custom-token", @configuration.token
  end

  def test_token_defaults_to_nil_without_env
    assert_nil @configuration.token
  end
end
