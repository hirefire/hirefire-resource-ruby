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

  def test_web_default_to_false
    refute @configuration.web
  end

  def test_workers_default_to_empty_array
    assert_empty @configuration.workers
  end

  def test_log_queue_metrics_default_to_false
    refute @configuration.log_queue_metrics
  end

  def test_can_set_log_queue_metrics
    @configuration.log_queue_metrics = true
    assert @configuration.log_queue_metrics
  end

  def test_dyno_configures_web_correctly
    @configuration.dyno(:web)
    assert_instance_of HireFire::Web, @configuration.web
  end

  def test_dyno_adds_block_configuration_to_workers
    worker_block = -> { 1 + 1 }
    @configuration.dyno(:worker, &worker_block)
    assert_equal 1, @configuration.workers.size
    assert_equal :worker, @configuration.workers[0].name
    assert_equal 2, @configuration.workers[0].value
  end
end
