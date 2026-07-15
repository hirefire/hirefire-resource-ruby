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

  def test_dyno_web_configures_http
    @configuration.dyno(:web)
    assert_instance_of HireFire::Web, @configuration.web
    assert_equal "web", @configuration.web.name
  end

  def test_dyno_web_is_case_insensitive_for_http
    @configuration.dyno("Web")
    assert_instance_of HireFire::Web, @configuration.web
    assert_equal "Web", @configuration.web.name
  end

  def test_dyno_with_a_block_configures_a_worker
    @configuration.dyno(:worker) { 1.23 }
    @configuration.dyno(:mailer) { 2.46 }
    workers = @configuration.workers.to_a
    assert_equal 2, workers.count
    assert_equal "worker", workers[0].name
    assert_equal 1.23, workers[0].sample
    assert_equal "mailer", workers[1].name
    assert_equal 2.46, workers[1].sample
  end

  def test_dyno_web_with_cpu_configures_cpu
    @configuration.dyno(:web, tracking: :cpu)
    assert_nil @configuration.web
    assert_equal ["web"], @configuration.cpu.map(&:name)
  end

  def test_dyno_non_web_with_cpu_configures_cpu
    @configuration.dyno(:clock, tracking: :cpu)
    assert_equal 1, @configuration.cpu.size
    assert_instance_of HireFire::CPU, @configuration.cpu.first
    assert_equal "clock", @configuration.cpu.first.name
  end

  def test_dyno_without_block_or_tracking_raises_for_a_non_web_name
    assert_raises(HireFire::Configuration::MissingSamplerError) do
      @configuration.dyno(:worker)
    end
  end

  def test_dyno_rejects_http_family_acronyms
    assert_raises(HireFire::Configuration::UnknownCollectorError) do
      @configuration.dyno(:web, tracking: :rqt)
    end
  end

  def test_dyno_rejects_the_http_keyword
    assert_raises(HireFire::Configuration::UnknownCollectorError) do
      @configuration.dyno(:web, tracking: :http)
    end
  end

  def test_dyno_rejects_job_family_acronyms
    assert_raises(HireFire::Configuration::UnknownCollectorError) do
      @configuration.dyno(:worker, tracking: :jql) { 1 }
    end
  end

  def test_dyno_cpu_rejects_a_sampler
    assert_raises(HireFire::Configuration::UnexpectedSamplerError) do
      @configuration.dyno(:web, tracking: :cpu) { 1 }
    end
  end

  def test_dyno_accepts_a_string_tracking_value
    @configuration.dyno(:clock, tracking: "cpu")
    assert_equal ["clock"], @configuration.cpu.map(&:name)
  end

  def test_service_http_configures_http
    @configuration.service(:web, tracking: :http)
    assert_instance_of HireFire::Web, @configuration.web
    assert_equal "web", @configuration.web.name
  end

  def test_service_http_allows_a_non_web_name
    @configuration.service(:api, tracking: :http)
    assert_equal "api", @configuration.web.name
  end

  def test_service_with_a_block_configures_a_worker
    @configuration.service(:worker) { 1.23 }
    workers = @configuration.workers.to_a
    assert_equal 1, workers.count
    assert_equal "worker", workers[0].name
    assert_equal 1.23, workers[0].sample
  end

  def test_service_cpu_configures_cpu
    @configuration.service(:clock, tracking: :cpu)
    assert_equal ["clock"], @configuration.cpu.map(&:name)
  end

  def test_service_with_keyword_and_block_raises
    assert_raises(HireFire::Configuration::UnexpectedSamplerError) do
      @configuration.service(:web, tracking: :http) { 1 }
    end
  end

  def test_service_cpu_with_block_raises
    assert_raises(HireFire::Configuration::UnexpectedSamplerError) do
      @configuration.service(:clock, tracking: :cpu) { 1 }
    end
  end

  def test_service_without_keyword_or_block_raises
    assert_raises(HireFire::Configuration::MissingSamplerError) do
      @configuration.service(:worker)
    end
  end

  def test_service_rejects_an_unknown_keyword
    assert_raises(HireFire::Configuration::UnknownCollectorError) do
      @configuration.service(:web, tracking: :foo)
    end
  end

  def test_service_accepts_a_string_tracking_value
    @configuration.service(:web, tracking: "http")
    assert_instance_of HireFire::Web, @configuration.web
  end

  def test_empty_name_raises
    assert_raises(ArgumentError) { @configuration.dyno(nil, tracking: :cpu) }
    assert_raises(ArgumentError) { @configuration.dyno("", tracking: :cpu) }
    assert_raises(ArgumentError) { @configuration.service(nil, tracking: :http) }
    assert_raises(ArgumentError) { @configuration.service("", tracking: :http) }
  end

  def test_duplicate_name_raises
    @configuration.dyno(:web)
    assert_raises(HireFire::Configuration::DuplicateDynoError) do
      @configuration.dyno(:web, tracking: :cpu)
    end
  end

  def test_duplicate_name_guard_spans_dyno_and_service_case_insensitively
    @configuration.dyno(:web)
    error = assert_raises(HireFire::Configuration::DuplicateDynoError) do
      @configuration.service(:Web, tracking: :http)
    end
    assert_includes error.message, "Web"
  end

  def test_second_http_declaration_under_a_different_name_raises
    @configuration.dyno(:web)
    error = assert_raises(HireFire::Configuration::DuplicateDynoError) do
      @configuration.service(:api, tracking: :http)
    end
    assert_includes error.message, "web"
  end

  def test_dyno_and_service_share_the_one_http_guard
    @configuration.service(:api, tracking: :http)
    assert_raises(HireFire::Configuration::DuplicateDynoError) do
      @configuration.dyno(:web)
    end
  end

  def test_rejected_declaration_does_not_reserve_the_name
    assert_raises(HireFire::Configuration::UnexpectedSamplerError) do
      @configuration.service(:web, tracking: :http) { 1 }
    end

    @configuration.service(:web, tracking: :http)
    assert_equal "web", @configuration.web.name
  end

  def test_dyno_and_service_register_into_the_same_collectors
    @configuration.dyno(:web)
    @configuration.service(:worker) { 1 }
    ENV["HIREFIRE_SERVICE_NAME"] = "clock"
    @configuration.service(:clock, tracking: :cpu)

    assert_equal "web", @configuration.web.name
    assert_equal ["worker"], @configuration.workers.map(&:name)
    assert_equal ["clock"], @configuration.cpu.map(&:name)
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
    @configuration.dyno(:clock, tracking: :cpu)
    active = @configuration.dispatcher.instance_variable_get(:@cpu)
    assert_equal ["clock"], active.map(&:name)
  end

  def test_cpu_collector_dormant_when_identity_differs
    ENV["DYNO"] = "web.1"
    @configuration.dyno(:clock, tracking: :cpu)
    active = @configuration.dispatcher.instance_variable_get(:@cpu)
    assert_empty active
  end

  def test_cpu_collector_disabled_and_logged_when_identity_unresolved
    log = StringIO.new
    @configuration.logger = Logger.new(log)
    @configuration.dyno(:clock, tracking: :cpu)
    active = @configuration.dispatcher.instance_variable_get(:@cpu)
    assert_empty active
    assert_includes log.string, "HIREFIRE_SERVICE_NAME"
  end

  def test_identity_resolution_skipped_with_only_job_collectors
    ENV["DYNO"] = "web.1"
    HireFire::Identity.expects(:resolve).never
    @configuration.dyno(:worker) { 1 }
    @configuration.dispatcher
  end

  def test_web_liveness_allowed_when_identity_matches
    ENV["DYNO"] = "web.1"
    @configuration.dyno(:web)
    assert @configuration.dispatcher.instance_variable_get(:@web_liveness)
  end

  def test_web_liveness_allowed_when_identity_unresolved
    @configuration.dyno(:web)
    assert @configuration.dispatcher.instance_variable_get(:@web_liveness)
  end

  def test_web_liveness_denied_when_identity_differs
    ENV["DYNO"] = "worker.1"
    @configuration.dyno(:web)
    refute @configuration.dispatcher.instance_variable_get(:@web_liveness)
  end

  def test_web_liveness_matches_non_web_http_names
    ENV["RENDER_SERVICE_NAME"] = "api"
    @configuration.service(:api, tracking: :http)
    assert @configuration.dispatcher.instance_variable_get(:@web_liveness)
  end

  def test_web_liveness_matches_case_insensitively
    ENV["DYNO"] = "Web.1"
    @configuration.dyno(:web)
    assert @configuration.dispatcher.instance_variable_get(:@web_liveness)
  end

  def test_cpu_collector_matches_case_insensitively
    ENV["DYNO"] = "Worker.1"
    @configuration.dyno(:worker, tracking: :cpu)
    active = @configuration.dispatcher.instance_variable_get(:@cpu)
    assert_equal ["worker"], active.map(&:name)
  end

  def test_heroku_config_var_conflict_is_warned
    ENV["DYNO"] = "worker.1"
    ENV["HIREFIRE_SERVICE_NAME"] = "web"
    log = StringIO.new
    @configuration.logger = Logger.new(log)
    @configuration.dyno(:worker, tracking: :cpu)
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

  def test_token_empty_string_is_not_overridden_by_env
    ENV["HIREFIRE_TOKEN"] = "from-env"
    @configuration.token = ""
    assert_equal "", @configuration.token
  end

  def test_token_nil_falls_back_to_env
    ENV["HIREFIRE_TOKEN"] = "from-env"
    @configuration.token = "custom-token"
    @configuration.token = nil
    assert_equal "from-env", @configuration.token
  end

  def test_dyno_rejects_a_positional_second_argument
    assert_raises(ArgumentError) { @configuration.dyno(:web, :cpu) }
  end

  def test_service_rejects_a_positional_second_argument
    assert_raises(ArgumentError) { @configuration.service(:web, :http) }
  end

  def test_web_liveness_true_without_a_web_collector
    ENV["HIREFIRE_SERVICE_NAME"] = "clock"
    @configuration.dyno(:clock, tracking: :cpu)
    assert @configuration.dispatcher.instance_variable_get(:@web_liveness)
  end

  def test_heroku_config_var_conflict_warned_only_once
    ENV["DYNO"] = "worker.1"
    ENV["HIREFIRE_SERVICE_NAME"] = "web"
    log = StringIO.new
    @configuration.logger = Logger.new(log)

    @configuration.dyno(:web)
    @configuration.dyno(:clock, tracking: :cpu)

    @configuration.dispatcher

    assert_equal 1, log.string.scan("app-wide").size
  end
end
