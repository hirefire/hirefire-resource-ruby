# frozen_string_literal: true

require "test_helper"

class HireFire::PlanTest < Minitest::Test
  def setup
    super
    HireFire.configuration.logger = Logger.new(File::NULL)
  end

  def test_known_adapters
    assert HireFire::Plan.known_adapter?("sidekiq")
    assert HireFire::Plan.known_adapter?("solid_queue")
    refute HireFire::Plan.known_adapter?("unknown")
  end

  def test_executable_requires_loaded_library
    refute HireFire::Plan.executable?("not_a_real_adapter")
  end

  def test_known_strategy
    assert HireFire::Plan.known_strategy?("jql")
    assert HireFire::Plan.known_strategy?("jqs")
    refute HireFire::Plan.known_strategy?("rpm")
  end

  def test_supports_strategy_rejects_latency_on_size_only_adapters
    refute HireFire::Plan.supports_strategy?("bunny", "jql")
    refute HireFire::Plan.supports_strategy?("resque", "jql")
    assert HireFire::Plan.supports_strategy?("bunny", "jqs")
    assert HireFire::Plan.supports_strategy?("resque", "jqs")
    assert HireFire::Plan.supports_strategy?("sidekiq", "jql")
    assert HireFire::Plan.supports_strategy?("sidekiq", "jqs")
    refute HireFire::Plan.supports_strategy?("unknown", "jql")
  end

  def test_supports_strategy_rejects_unknown_strategy_with_known_adapter
    refute HireFire::Plan.supports_strategy?("sidekiq", "rpm")
    refute HireFire::Plan.supports_strategy?("sidekiq", "unknown")
    refute HireFire::Plan.supports_strategy?("bunny", "jql")
  end

  def test_execute_skips_unsupported_strategy_without_calling_macro
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)
    original = HireFire::Plan::ADAPTERS
    original_checks = HireFire::Plan::LIBRARY_CHECKS
    called = false
    mod = stub_macro do |m|
      m.extend(HireFire::Errors::JobQueueLatencyUnsupported)
      m.define_singleton_method(:job_queue_size) { |*_queues, **_options| called = true; 1 }
    end

    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original.merge("bunny" => mod))
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks.merge("bunny" => -> { true }))

    HireFire::Plan.execute(
      "name" => "worker",
      "adapter" => "bunny",
      "strategy" => "jql",
      "queues" => ["default"],
      "options" => {}
    )

    refute called
    assert_empty HireFire.configuration.buffer.flush
    assert_includes log.string, "does not support"
    assert_includes log.string, "jql"
  ensure
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original)
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks)
  end

  def test_library_loaded_and_executable_with_stubbed_check
    original_checks = HireFire::Plan::LIBRARY_CHECKS
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks.merge("sidekiq" => -> { true }))

    assert HireFire::Plan.library_loaded?("sidekiq")
    assert HireFire::Plan.executable?("sidekiq")
    refute HireFire::Plan.library_loaded?("not_a_real_adapter")
  ensure
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks)
  end

  def test_any_allowlisted_job_queue_library_loaded
    original_checks = HireFire::Plan::LIBRARY_CHECKS
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, {"sidekiq" => -> { false }, "resque" => -> { true }})

    assert HireFire::Plan.any_allowlisted_job_queue_library_loaded?

    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, {"sidekiq" => -> { false }})
    refute HireFire::Plan.any_allowlisted_job_queue_library_loaded?
  ensure
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks)
  end

  def test_execute_unknown_adapter_logs_and_skips
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)

    HireFire::Plan.execute(
      "name" => "worker",
      "adapter" => "nope",
      "strategy" => "jql",
      "queues" => [],
      "options" => {}
    )

    assert_empty HireFire.configuration.buffer.flush
    assert_includes log.string, "Unknown plan adapter"
  end

  def test_execute_unknown_strategy_logs_and_skips
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)

    HireFire::Plan.execute(
      "name" => "worker",
      "adapter" => "sidekiq",
      "strategy" => "rpm",
      "queues" => [],
      "options" => {}
    )

    assert_empty HireFire.configuration.buffer.flush
    assert_includes log.string, "Unknown plan strategy"
  end

  def test_execute_calls_macro_and_buffers_nested_metric
    original = HireFire::Plan::ADAPTERS
    original_checks = HireFire::Plan::LIBRARY_CHECKS
    mod = stub_macro do |m|
      m.define_singleton_method(:job_queue_latency) { |*_queues, **_options| 1.5 }
    end

    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original.merge("sidekiq" => mod))
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks.merge("sidekiq" => -> { true }))

    HireFire::Plan.execute(
      "name" => "worker",
      "adapter" => "sidekiq",
      "strategy" => "jql",
      "queues" => ["default"],
      "options" => {"skip_retries" => true, "bogus" => true}
    )

    data = HireFire.configuration.buffer.flush
    assert_equal 1.5, data["worker"]["jql"].values.first
  ensure
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original)
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks)
  end

  def test_execute_merges_adapter_plan_options
    captured = nil
    original = HireFire::Plan::ADAPTERS
    original_checks = HireFire::Plan::LIBRARY_CHECKS
    mod = stub_macro do |m|
      m.define_singleton_method(:plan_options) do |strategy, options|
        HireFire::Macro::Sidekiq.plan_options(strategy, options)
      end
      m.define_singleton_method(:job_queue_size) do |*_queues, **options|
        captured = options
        3
      end
    end

    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original.merge("sidekiq" => mod))
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks.merge("sidekiq" => -> { true }))

    HireFire::Plan.execute(
      "name" => "worker",
      "adapter" => "sidekiq",
      "strategy" => "jqs",
      "queues" => ["default"],
      "options" => {
        "skip_working" => true,
        "server" => true,
        "not_allowed" => true
      }
    )

    assert_equal({skip_working: true, server: true}, captured)
  ensure
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original)
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks)
  end

  def test_execute_merges_adapter_plan_connection_options
    captured = nil
    original = HireFire::Plan::ADAPTERS
    original_checks = HireFire::Plan::LIBRARY_CHECKS
    mod = stub_macro do |m|
      m.define_singleton_method(:plan_connection_options) do
        HireFire::Macro::Bunny.plan_connection_options
      end
      m.define_singleton_method(:job_queue_size) do |*_queues, **options|
        captured = options
        0
      end
    end

    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original.merge("bunny" => mod))
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks.merge("bunny" => -> { true }))
    ENV["HIREFIRE_BUNNY_URL"] = "amqp://override.example/vhost"

    HireFire::Plan.execute(
      "name" => "worker",
      "adapter" => "bunny",
      "strategy" => "jqs",
      "queues" => ["default"],
      "options" => {}
    )

    assert_equal({amqp_url: "amqp://override.example/vhost"}, captured)
  ensure
    ENV.delete("HIREFIRE_BUNNY_URL")
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original)
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks)
  end

  def test_macros_expose_plan_hooks_with_empty_defaults
    [
      HireFire::Macro::SolidQueue,
      HireFire::Macro::GoodJob,
      HireFire::Macro::Que,
      HireFire::Macro::QC,
      HireFire::Macro::Delayed::Job,
      HireFire::Macro::Resque,
      HireFire::Macro::Bunny
    ].each do |macro|
      assert_equal({}, macro.plan_options("jql", {"any" => true}))
      assert_equal({}, macro.plan_connection_options) unless macro == HireFire::Macro::Bunny
    end
    assert_equal({}, HireFire::Macro::Bunny.plan_connection_options)
  end

  def test_size_only_macros_reject_jql_strategy_support
    [HireFire::Macro::Bunny, HireFire::Macro::Resque].each do |macro|
      refute macro.supports_plan_strategy?("jql")
      assert macro.supports_plan_strategy?("jqs")
    end
    assert HireFire::Macro::Sidekiq.supports_plan_strategy?("jql")
  end

  def test_execute_drops_invalid_samples
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)
    original = HireFire::Plan::ADAPTERS
    original_checks = HireFire::Plan::LIBRARY_CHECKS

    [-1, Float::NAN, Float::INFINITY, nil, "nope"].each do |bad|
      mod = stub_macro do |m|
        m.define_singleton_method(:job_queue_latency) { |*_queues, **_options| bad }
      end
      HireFire::Plan.send(:remove_const, :ADAPTERS)
      HireFire::Plan.const_set(:ADAPTERS, original.merge("sidekiq" => mod))
      HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
      HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks.merge("sidekiq" => -> { true }))

      HireFire::Plan.execute(
        "name" => "worker",
        "adapter" => "sidekiq",
        "strategy" => "jql",
        "queues" => [],
        "options" => {}
      )
    end

    assert_empty HireFire.configuration.buffer.flush
    assert_operator log.string.scan("Sample dropped").size, :>=, 5
  ensure
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original)
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks)
  end

  def test_execute_rescues_macro_errors_and_logs
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)
    original = HireFire::Plan::ADAPTERS
    original_checks = HireFire::Plan::LIBRARY_CHECKS
    mod = stub_macro do |m|
      m.define_singleton_method(:job_queue_latency) { |*_queues, **_options| raise "redis down" }
    end

    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original.merge("sidekiq" => mod))
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks.merge("sidekiq" => -> { true }))

    HireFire::Plan.execute(
      "name" => "worker",
      "adapter" => "sidekiq",
      "strategy" => "jql",
      "queues" => [],
      "options" => {}
    )

    assert_empty HireFire.configuration.buffer.flush
    assert_includes log.string, "Plan sampler for \"worker\" raised"
    assert_includes log.string, "redis down"
  ensure
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original)
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks)
  end

  def test_execute_coerces_non_float_numeric_samples
    original = HireFire::Plan::ADAPTERS
    original_checks = HireFire::Plan::LIBRARY_CHECKS
    mod = stub_macro do |m|
      m.define_singleton_method(:job_queue_latency) { |*_queues, **_options| Rational(3, 2) }
    end

    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original.merge("sidekiq" => mod))
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks.merge("sidekiq" => -> { true }))

    HireFire::Plan.execute(
      "name" => "worker",
      "adapter" => "sidekiq",
      "strategy" => "jql",
      "queues" => [],
      "options" => {}
    )

    value = HireFire.configuration.buffer.flush["worker"]["jql"].values.first
    assert_kind_of Float, value
    assert_in_delta 1.5, value, 0.0001
  ensure
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original)
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks)
  end

  def test_normalize_queues_truncates_and_strips
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)
    queues = (HireFire::Plan::MAX_QUEUES + 2).times.map { |i| " q#{i} " }
    queues << ""
    queues << ("x" * (HireFire::Plan::MAX_QUEUE_NAME_BYTES + 1))

    normalized = HireFire::Plan.send(:normalize_queues, queues)

    assert_equal HireFire::Plan::MAX_QUEUES, normalized.size
    assert_equal "q0", normalized.first
    assert_includes log.string, "truncated"
  end

  private

  def stub_macro
    mod = Module.new
    mod.extend(HireFire::Plan::Hooks)
    yield mod
    mod
  end
end
