# frozen_string_literal: true

require "test_helper"

class HireFire::ConfigurationTest < Minitest::Test
  def setup
    super
    @configuration = HireFire::Configuration.new
    @configuration.logger = Logger.new(File::NULL)
  end

  def test_default_logger_points_to_stdout
    configuration = HireFire::Configuration.new
    assert_equal $stdout, configuration.logger.instance_variable_get(:@logdev).dev
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

  def test_cpu_defaults_to_empty
    assert_empty @configuration.cpu
  end

  def test_rqt_configures_web
    @configuration.dyno(:web, :rqt)
    assert_instance_of HireFire::Web, @configuration.web
    assert_equal "web", @configuration.web.name
  end

  def test_rpm_configures_web
    @configuration.dyno(:web, :rpm)
    assert_instance_of HireFire::Web, @configuration.web
  end

  def test_http_collector_allows_a_non_web_name
    @configuration.dyno(:api, :rqt)
    assert_equal "api", @configuration.web.name
  end

  def test_jql_configures_worker
    @configuration.dyno(:worker, :jql) { 1.23 }
    @configuration.dyno(:mailer, :jqs) { 2.46 }
    workers = @configuration.workers.to_a
    assert_equal 2, workers.count
    assert_equal "worker", workers[0].name
    assert_equal 1.23, workers[0].sample
    assert_equal "mailer", workers[1].name
    assert_equal 2.46, workers[1].sample
  end

  def test_cpu_configures_collector
    @configuration.dyno(:clock, :cpu)
    assert_equal 1, @configuration.cpu.size
    assert_instance_of HireFire::CPU, @configuration.cpu.first
    assert_equal "clock", @configuration.cpu.first.name
  end

  def test_unknown_strategy_raises
    assert_raises(HireFire::Configuration::UnknownStrategyError) do
      @configuration.dyno(:web, :bogus)
    end
  end

  def test_duplicate_name_raises
    @configuration.dyno(:web, :rqt)
    assert_raises(HireFire::Configuration::DuplicateDynoError) do
      @configuration.dyno(:web, :cpu)
    end
  end

  def test_duplicate_name_check_is_case_insensitive
    @configuration.dyno(:worker, :jql) { 1 }
    assert_raises(HireFire::Configuration::DuplicateDynoError) do
      @configuration.dyno("Worker", :cpu)
    end
  end

  def test_second_http_strategy_raises
    @configuration.dyno(:web, :rqt)
    error = assert_raises(HireFire::Configuration::DuplicateDynoError) do
      @configuration.dyno(:api, :rpm)
    end
    assert_includes error.message, "web"
  end

  def test_empty_name_raises
    assert_raises(ArgumentError) { @configuration.dyno(nil, :rqt) }
    assert_raises(ArgumentError) { @configuration.dyno("", :rqt) }
  end

  def test_nil_strategy_raises_unknown_strategy
    assert_raises(HireFire::Configuration::UnknownStrategyError) do
      @configuration.dyno(:web, nil)
    end
  end

  def test_string_strategy_accepted
    @configuration.dyno(:web, "rqt")
    assert_instance_of HireFire::Web, @configuration.web
  end

  def test_job_strategy_requires_a_sampler
    assert_raises(HireFire::Configuration::MissingSamplerError) do
      @configuration.dyno(:worker, :jql)
    end
  end

  def test_http_strategy_rejects_a_sampler
    assert_raises(HireFire::Configuration::UnexpectedSamplerError) do
      @configuration.dyno(:web, :rqt) { 1 }
    end
  end

  def test_cpu_strategy_rejects_a_sampler
    assert_raises(HireFire::Configuration::UnexpectedSamplerError) do
      @configuration.dyno(:clock, :cpu) { 1 }
    end
  end

  def test_dispatcher_returns_instance
    assert_instance_of HireFire::Dispatcher, @configuration.dispatcher
  end

  def test_dispatcher_is_memoized
    assert_same @configuration.dispatcher, @configuration.dispatcher
  end

  def test_dispatcher_receives_web
    @configuration.dyno(:web, :rqt)
    d = @configuration.dispatcher
    assert_equal @configuration.web, d.instance_variable_get(:@web)
  end

  def test_dispatcher_receives_workers
    @configuration.dyno(:worker, :jql) { 1 }
    d = @configuration.dispatcher
    assert_same @configuration.workers, d.instance_variable_get(:@workers)
  end

  def test_dispatcher_without_web
    d = @configuration.dispatcher
    assert_nil d.instance_variable_get(:@web)
  end

  def test_buffer_returns_instance
    assert_instance_of HireFire::Buffer, @configuration.buffer
  end

  def test_buffer_is_memoized
    assert_same @configuration.buffer, @configuration.buffer
  end

  def test_cpu_collector_active_when_identity_matches
    ENV["HIREFIRE_SERVICE_NAME"] = "clock"
    @configuration.dyno(:clock, :cpu)
    active = @configuration.dispatcher.instance_variable_get(:@cpu)
    assert_equal ["clock"], active.map(&:name)
  end

  def test_cpu_collector_dormant_when_identity_differs
    ENV["DYNO"] = "web.1"
    @configuration.dyno(:clock, :cpu)
    active = @configuration.dispatcher.instance_variable_get(:@cpu)
    assert_empty active
  end

  def test_cpu_collector_disabled_and_logged_when_identity_unresolved
    log = StringIO.new
    @configuration.logger = Logger.new(log)
    @configuration.dyno(:clock, :cpu)
    active = @configuration.dispatcher.instance_variable_get(:@cpu)
    assert_empty active
    assert_includes log.string, "HIREFIRE_SERVICE_NAME"
  end

  def test_identity_resolution_skipped_with_only_job_collectors
    ENV["DYNO"] = "web.1"
    HireFire::Identity.expects(:resolve).never
    @configuration.dyno(:worker, :jql) { 1 }
    @configuration.dispatcher
  end

  def test_web_liveness_allowed_when_identity_matches
    ENV["DYNO"] = "web.1"
    @configuration.dyno(:web, :rqt)
    assert @configuration.dispatcher.instance_variable_get(:@web_liveness)
  end

  def test_web_liveness_allowed_when_identity_unresolved
    @configuration.dyno(:web, :rqt)
    assert @configuration.dispatcher.instance_variable_get(:@web_liveness)
  end

  def test_web_liveness_denied_when_identity_differs
    ENV["DYNO"] = "worker.1"
    @configuration.dyno(:web, :rqt)
    refute @configuration.dispatcher.instance_variable_get(:@web_liveness)
  end

  def test_web_liveness_matches_non_web_http_names
    ENV["RENDER_SERVICE_NAME"] = "api"
    @configuration.dyno(:api, :rqt)
    assert @configuration.dispatcher.instance_variable_get(:@web_liveness)
  end

  def test_web_liveness_matches_case_insensitively
    ENV["DYNO"] = "Web.1"
    @configuration.dyno(:web, :rqt)
    assert @configuration.dispatcher.instance_variable_get(:@web_liveness)
  end

  def test_cpu_collector_matches_case_insensitively
    ENV["DYNO"] = "Worker.1"
    @configuration.dyno(:worker, :cpu)
    active = @configuration.dispatcher.instance_variable_get(:@cpu)
    assert_equal ["worker"], active.map(&:name)
  end

  def test_heroku_config_var_conflict_is_warned
    ENV["DYNO"] = "worker.1"
    ENV["HIREFIRE_SERVICE_NAME"] = "web"
    log = StringIO.new
    @configuration.logger = Logger.new(log)
    @configuration.dyno(:worker, :cpu)
    @configuration.dispatcher
    assert_includes log.string, "app-wide"
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
