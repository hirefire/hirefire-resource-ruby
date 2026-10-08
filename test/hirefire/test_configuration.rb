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

  def test_log_queue_metrics_is_false_until_it_is_set
    assert_equal false, @configuration.log_queue_metrics
  end

  def test_job_queues_default_to_empty
    assert @configuration.job_queues.none?
  end

  def test_dyno_bare_web_is_noop
    @configuration.dyno(:web)
    refute @configuration.rqt_enabled?
    assert @configuration.job_queues.none?
  end

  def test_dyno_bare_web_is_case_insensitive_noop
    @configuration.dyno("Web")
    refute @configuration.rqt_enabled?
  end

  def test_dyno_bare_web_warns_once
    log = StringIO.new
    @configuration.logger = Logger.new(log)

    @configuration.dyno(:web)
    @configuration.dyno(:Web)

    assert_equal 1, log.string.scan("config.dyno(:web) is deprecated").size
    assert_includes log.string, "You can remove"
    assert_includes log.string, "does nothing"
  end

  def test_dyno_with_a_block_configures_a_job_queue
    @configuration.dyno(:worker) { 1.23 }
    @configuration.dyno(:mailer) { 2.46 }
    job_queues = @configuration.job_queues.to_a
    assert_equal 2, job_queues.count
    assert_equal "worker", job_queues[0].name
    assert_equal 1.23, job_queues[0].sample
    assert_equal "mailer", job_queues[1].name
    assert_equal 2.46, job_queues[1].sample
  end

  def test_dyno_accepts_hyphenated_name_string_and_symbol
    @configuration.dyno("worker-latency") { 1.5 }
    @configuration.dyno(:"worker-size") { 2 }
    names = @configuration.job_queues.map(&:name)
    assert_equal ["worker-latency", "worker-size"], names
    assert_equal 1.5, @configuration.job_queues.find_by_name("worker-latency").sample
    assert_equal 2, @configuration.job_queues.find_by_name(:"worker-size").sample
  end

  def test_dyno_without_block_raises_for_a_non_web_name
    assert_raises(HireFire::Errors::MissingSamplerError) do
      @configuration.dyno(:worker)
    end
  end

  def test_dyno_rejects_tracking_keyword
    assert_raises(ArgumentError) do
      @configuration.dyno(:web, tracking: :cpu)
    end
  end

  def test_empty_name_raises
    assert_raises(ArgumentError) { @configuration.dyno(nil) }
    assert_raises(ArgumentError) { @configuration.dyno("") }
    assert_raises(ArgumentError) { @configuration.dyno("   ") }
  end

  def test_dyno_strips_name_whitespace
    @configuration.dyno("  worker  ") { 1 }
    assert_equal "worker", @configuration.job_queues.find_by_name("worker").name
  end

  def test_dyno_rejects_name_over_max_bytes
    too_long = "w" * (128 + 1)
    error = assert_raises(ArgumentError) { @configuration.dyno(too_long) { 1 } }
    assert_includes error.message, "128"
  end

  def test_dyno_name_errors_say_what_was_given
    error = assert_raises(ArgumentError) { @configuration.dyno("  ") }
    assert_equal 'config.dyno requires a dyno name as its first argument (got "").', error.message

    error = assert_raises(ArgumentError) { @configuration.dyno("w" * 129) { 1 } }
    assert_equal "config.dyno name exceeds 128 bytes (got 129).", error.message
  end

  def test_an_identity_of_exactly_the_limit_is_used_and_one_byte_more_is_not
    log = StringIO.new
    @configuration.logger = Logger.new(log)

    ENV["HIREFIRE_SERVICE_NAME"] = "x" * 128
    assert_equal "x" * 128, @configuration.http_name
    assert_empty log.string

    ENV["HIREFIRE_SERVICE_NAME"] = "x" * 129
    assert_nil @configuration.http_name
    assert_includes log.string, "[HireFire] Process identity exceeds 128 bytes (129). Metrics under this identity are disabled until the name is shortened."
  end

  def test_requests_without_an_identity_warn_once_that_their_samples_are_dropped
    ENV["HIREFIRE_TOKEN"] = "token"
    log = StringIO.new
    @configuration.logger = Logger.new(log)
    @configuration.dispatcher.stubs(:start).returns(false)

    2.times { @configuration.sample_request_queue_time(5) }

    assert_equal 1, log.string.scan("[HireFire] Request queue time samples dropped: process identity is unresolved. Set HIREFIRE_SERVICE_NAME or DYNO.").size
  end

  def test_the_cpu_source_is_kept_while_the_identity_stays_and_rebuilt_when_it_changes
    ENV["DYNO"] = "api.1"
    first = @configuration.active_cpu_sources.first
    assert_same first, @configuration.active_cpu_sources.first

    ENV["DYNO"] = "worker.1"
    second = @configuration.active_cpu_sources.first

    refute_same first, second
    assert_equal "worker", second.name
  end

  def test_the_identity_warnings_say_what_was_found_and_what_to_set
    log = StringIO.new
    @configuration.logger = Logger.new(log)

    @configuration.active_cpu_sources
    assert_includes log.string, "[HireFire] CPU metrics disabled: process identity is unresolved. Set HIREFIRE_SERVICE_NAME or DYNO."

    ENV["DYNO"] = "worker.1"
    ENV["HIREFIRE_SERVICE_NAME"] = "web"
    @configuration.active_cpu_sources
    assert_includes log.string, "[HireFire] HIREFIRE_SERVICE_NAME (web) does not match the Heroku DYNO prefix (worker)."
  end

  def test_dyno_name_limit_counts_utf8_bytes
    accepted = "é" * 64
    too_long = "é" * 65

    @configuration.dyno(accepted) { 1 }
    assert_equal accepted, @configuration.job_queues.first.name
    assert_raises(ArgumentError) { @configuration.dyno(too_long) { 1 } }
  end

  def test_using_default_logger_flag
    configuration = HireFire::Configuration.new
    assert configuration.using_default_logger?

    configuration.logger = Logger.new(File::NULL)
    refute configuration.using_default_logger?
  end

  def test_duplicate_job_queue_raises
    @configuration.dyno(:worker) { 1 }
    assert_raises(HireFire::Errors::DuplicateDynoError) do
      @configuration.dyno(:worker) { 2 }
    end
  end

  def test_duplicate_name_guard_is_case_insensitive
    @configuration.dyno(:worker) { 1 }
    error = assert_raises(HireFire::Errors::DuplicateDynoError) do
      @configuration.dyno(:Worker) { 2 }
    end
    assert_includes error.message, "Worker"
  end

  def test_bare_web_then_job_queue_under_web
    @configuration.dyno(:web)
    @configuration.dyno(:web) { 1 }

    assert_equal ["web"], @configuration.job_queues.map(&:name)
  end

  def test_http_name_not_forced_by_bare_web
    @configuration.dyno(:web)
    assert_nil @configuration.http_name
  end

  def test_http_name_nil_without_explicit_or_identity
    assert_nil @configuration.http_name
  end

  def test_http_name_uses_identity_when_unconfigured
    ENV["DYNO"] = "api.1"
    assert_equal "api", @configuration.http_name
  end

  def test_dispatcher_returns_instance
    assert_instance_of HireFire::Dispatcher, @configuration.dispatcher
  end

  def test_dispatcher_is_memoized
    assert_same @configuration.dispatcher, @configuration.dispatcher
  end

  def test_buffer_returns_instance
    assert_instance_of HireFire::Buffer, @configuration.buffer
  end

  def test_buffer_is_memoized
    assert_same @configuration.buffer, @configuration.buffer
  end

  def test_always_on_cpu_when_identity_resolves
    ENV["DYNO"] = "worker.1"
    active = @configuration.active_cpu_sources
    assert_equal ["worker"], active.map(&:name)
  end

  def test_cpu_disabled_when_identity_unresolved
    assert_empty @configuration.active_cpu_sources
  end

  def test_cpu_disabled_logs_once_when_identity_unresolved
    log = StringIO.new
    @configuration.logger = Logger.new(log)

    assert_empty @configuration.active_cpu_sources
    assert_empty @configuration.active_cpu_sources

    assert_equal 1, log.string.scan("CPU metrics disabled").size
  end

  def test_token_whitespace_only_is_treated_as_absent
    ENV["HIREFIRE_TOKEN"] = "   "
    assert_nil @configuration.token

    @configuration.token = "  \t  "
    assert_nil @configuration.token
  end

  def test_dispatcher_construction_does_not_require_identity
    ENV["DYNO"] = "web.1"
    @configuration.dyno(:worker) { 1 }
    assert_instance_of HireFire::Dispatcher, @configuration.dispatcher
  end

  def test_a_web_identity_enables_request_queue_time_under_its_name
    ENV["DYNO"] = "web.1"
    assert @configuration.rqt_enabled?
    assert_equal "web", @configuration.http_name
  end

  def test_traffic_without_an_identity_enables_request_queue_time_without_a_name
    @configuration.mark_http_active!
    assert @configuration.rqt_enabled?
    assert_nil @configuration.http_name
  end

  def test_traffic_on_a_worker_identity_enables_request_queue_time_under_its_name
    ENV["DYNO"] = "worker.1"
    @configuration.mark_http_active!
    assert @configuration.rqt_enabled?
    assert_equal "worker", @configuration.http_name
  end

  def test_soft_identity_over_max_bytes_disables_http_and_cpu_and_warns_once
    ENV["HIREFIRE_SERVICE_NAME"] = "x" * (HireFire::Identity::MAX_NAME_BYTES + 1)
    log = StringIO.new
    @configuration.logger = Logger.new(log)

    refute @configuration.http_source
    assert_empty @configuration.active_cpu_sources
    assert_equal 1, log.string.scan("Process identity exceeds").size

    refute @configuration.http_source
    assert_empty @configuration.active_cpu_sources
    assert_equal 1, log.string.scan("Process identity exceeds").size
  end

  def test_bare_web_does_not_arm_rqt
    @configuration.dyno(:web)
    refute @configuration.rqt_enabled?
  end

  def test_always_on_cpu_matches_case_insensitively
    ENV["DYNO"] = "Worker.1"
    active = @configuration.active_cpu_sources
    assert_equal ["Worker"], active.map(&:name)
  end

  def test_heroku_config_var_conflict_is_warned
    ENV["DYNO"] = "worker.1"
    ENV["HIREFIRE_SERVICE_NAME"] = "web"
    log = StringIO.new
    @configuration.logger = Logger.new(log)
    @configuration.active_cpu_sources
    assert_includes log.string, "app-wide"
  end

  def test_log_queue_metrics_defaults_to_false
    refute @configuration.log_queue_metrics
  end

  def test_log_queue_metrics_can_be_set
    @configuration.log_queue_metrics = true
    assert @configuration.log_queue_metrics
  end

  def test_log_queue_metrics_true_warns_once
    log = StringIO.new
    @configuration.logger = Logger.new(log)

    @configuration.log_queue_metrics = true
    @configuration.log_queue_metrics = true

    assert_equal 1, log.string.scan("config.log_queue_metrics is deprecated").size
    assert_includes log.string, "HireFire Request Queue Time"
    assert_includes log.string, "HIREFIRE_TOKEN"
    assert_includes log.string, "remove this log_queue_metrics = true line"
    assert_includes log.string, "still emit"
    assert_includes log.string, "Logplex - Request Queue Time"
  end

  def test_log_queue_metrics_false_is_silent
    log = StringIO.new
    @configuration.logger = Logger.new(log)

    @configuration.log_queue_metrics = false

    assert_empty log.string
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

  def test_token_empty_string_is_treated_as_absent
    ENV["HIREFIRE_TOKEN"] = "from-env"
    @configuration.token = ""
    assert_nil @configuration.token
  end

  def test_token_empty_env_is_treated_as_absent
    ENV["HIREFIRE_TOKEN"] = ""
    assert_nil @configuration.token
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

  def test_rqt_not_enabled_for_non_http_identity_without_explicit_web
    ENV["HIREFIRE_SERVICE_NAME"] = "clock"
    refute @configuration.rqt_enabled?
  end

  def test_rqt_enabled_for_heroku_web_process_without_explicit_web
    ENV["DYNO"] = "web.1"
    assert @configuration.rqt_enabled?
  end

  def test_rqt_enabled_for_render_web_service_type
    ENV["RENDER_SERVICE_NAME"] = "api"
    ENV["RENDER_SERVICE_TYPE"] = "web"
    assert @configuration.rqt_enabled?
    assert_equal "api", @configuration.http_name
  end

  def test_rqt_not_enabled_for_render_worker_without_traffic
    ENV["RENDER_SERVICE_NAME"] = "worker"
    ENV["RENDER_SERVICE_TYPE"] = "worker"
    refute @configuration.rqt_enabled?
  end

  def test_rqt_enabled_after_middleware_marks_http_active
    ENV["HIREFIRE_SERVICE_NAME"] = "api"
    refute @configuration.rqt_enabled?
    @configuration.mark_http_active!
    assert @configuration.rqt_enabled?
    assert_equal "api", @configuration.http_name
  end

  def test_rqt_not_enabled_by_explicit_service_name_web_on_worker_dyno
    ENV["HIREFIRE_SERVICE_NAME"] = "web"
    ENV["DYNO"] = "worker.1"
    refute @configuration.rqt_enabled?
  end

  def test_heroku_config_var_conflict_warned_only_once
    ENV["DYNO"] = "worker.1"
    ENV["HIREFIRE_SERVICE_NAME"] = "web"
    log = StringIO.new
    @configuration.logger = Logger.new(log)

    @configuration.active_cpu_sources
    @configuration.http_name

    assert_equal 1, log.string.scan("app-wide").size
  end

  def test_token_strips_surrounding_whitespace
    ENV["HIREFIRE_TOKEN"] = "  abc  "
    assert_equal "abc", @configuration.token

    @configuration.token = "  def\t"
    assert_equal "def", @configuration.token
  end

  def test_http_source_rebuilds_when_identity_name_changes
    ENV["DYNO"] = "api.1"
    first = @configuration.http_source
    assert_equal "api", first.name
    assert_same first, @configuration.http_source

    ENV["DYNO"] = "web.1"
    second = @configuration.http_source
    assert_equal "web", second.name
    refute_same first, second
  end

  def test_requests_are_recorded_under_the_identity_read_at_the_last_dispatcher_start
    ENV["HIREFIRE_TOKEN"] = "token"
    ENV["HIREFIRE_SERVICE_NAME"] = "first"
    @configuration.dispatcher.stubs(:start).returns(true, false, false, true, false)

    2.times { @configuration.sample_request_queue_time(5) }
    ENV["HIREFIRE_SERVICE_NAME"] = "second"
    @configuration.sample_request_queue_time(5)
    assert_equal ["first"], @configuration.buffer.flush.keys

    2.times { @configuration.sample_request_queue_time(5) }
    assert_equal ["first", "second"], @configuration.buffer.flush.keys
  end

  def test_the_token_is_read_again_only_when_the_dispatcher_starts
    ENV["HIREFIRE_TOKEN"] = "token"
    ENV["HIREFIRE_SERVICE_NAME"] = "web"
    @configuration.dispatcher.stubs(:start).returns(false, false, true, false)

    @configuration.sample_request_queue_time(5)
    ENV.delete("HIREFIRE_TOKEN")
    2.times { @configuration.sample_request_queue_time(5) }
    assert_equal 3, @configuration.buffer.flush.dig("web", "rqt").values.sum { |bucket| bucket[:count] }

    @configuration.sample_request_queue_time(5)
    assert_empty @configuration.buffer.flush
  end

  def test_setting_the_token_makes_the_next_request_read_it
    ENV["HIREFIRE_SERVICE_NAME"] = "web"
    @configuration.token = "token"
    @configuration.dispatcher.stubs(:start).returns(false)

    @configuration.sample_request_queue_time(5)
    @configuration.token = ""
    @configuration.sample_request_queue_time(5)

    assert_equal 1, @configuration.buffer.flush.dig("web", "rqt").values.sum { |bucket| bucket[:count] }
  end

  def test_a_request_with_a_token_and_no_identity_records_nothing_and_starts_the_dispatcher
    ENV["HIREFIRE_TOKEN"] = "token"
    @configuration.dispatcher.expects(:start).twice.returns(false)

    2.times { @configuration.sample_request_queue_time(5) }

    assert_empty @configuration.buffer.flush
  end

  def test_a_request_without_a_token_records_nothing_and_starts_nothing
    ENV["DYNO"] = "web.1"
    @configuration.dispatcher.expects(:start).never

    @configuration.sample_request_queue_time(5)

    assert_empty @configuration.buffer.flush
  end

  def test_a_fork_reset_makes_the_next_request_read_the_identity_again
    ENV["HIREFIRE_TOKEN"] = "token"
    ENV["HIREFIRE_SERVICE_NAME"] = "first"
    @configuration.dispatcher.stubs(:start).returns(false)

    @configuration.sample_request_queue_time(5)
    ENV["HIREFIRE_SERVICE_NAME"] = "second"
    @configuration.reset_after_fork
    @configuration.sample_request_queue_time(5)

    assert_equal ["first", "second"], @configuration.buffer.flush.keys
  end

  def test_canonical_name_preserves_first_seen_casing
    @configuration.dyno(:Web) { 1 }
    assert_equal "Web", @configuration.job_queues.find_by_name("Web").name
  end

  def test_reset_after_fork_clears_always_on_sources
    ENV["DYNO"] = "web.1"
    cpu = @configuration.active_cpu_sources.first
    http = @configuration.http_source
    assert cpu
    assert http

    @configuration.reset_after_fork

    refute_same cpu, @configuration.active_cpu_sources.first
    refute_same http, @configuration.http_source
  end

  def test_missing_sampler_error_message_mentions_sampler
    error = assert_raises(HireFire::Errors::MissingSamplerError) do
      @configuration.dyno(:worker)
    end
    assert_includes error.message, "sampler"
    assert_includes error.message, "worker"
  end

  def test_stop_dispatcher_stops_memoized_dispatcher
    dispatcher = @configuration.dispatcher
    dispatcher.expects(:stop).once
    @configuration.stop_dispatcher
  end
end
