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
    assert_empty @configuration.workers
  end

  def test_configure_web
    @configuration.dyno(:web)
    assert_instance_of HireFire::Web, @configuration.web
  end

  def test_configure_workers
    @configuration.dyno(:worker) { 1.23 }
    @configuration.dyno(:mailer) { 2.46 }
    assert_equal 2, @configuration.workers.size
    assert_equal :worker, @configuration.workers[0].name
    assert_equal 1.23, @configuration.workers[0].value
    assert_equal :mailer, @configuration.workers[1].name
    assert_equal 2.46, @configuration.workers[1].value
  end

  def test_log_queue_metrics_defaults_to_false
    refute @configuration.log_queue_metrics
  end

  def test_log_queue_metrics_can_be_set
    @configuration.log_queue_metrics = true
    assert @configuration.log_queue_metrics
  end
end
