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
    refute HireFire::Plan.known_strategy?("wrk")
  end

  def test_execute_skips_wrk_when_macro_lacks_job_queue_working
    buffer = HireFire.configuration.buffer
    buffer.flush
    original = HireFire::Plan::ADAPTERS
    original_checks = HireFire::Plan::LIBRARY_CHECKS
    mod = stub_macro do |m|
      m.define_singleton_method(:job_queue_size) { |*_a, **_o| 7 }
    end
    refute mod.respond_to?(:job_queue_working)

    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original.merge("sidekiq" => mod))
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks.merge("sidekiq" => -> { true }))

    HireFire::Plan.execute(
      "name" => "worker",
      "adapter" => "sidekiq",
      "strategy" => "jqs",
      "queues" => ["default"],
      "options" => {}
    )

    flushed = buffer.flush
    assert_equal 7, flushed.dig("worker", "jqs")&.values&.last
    assert_nil flushed.dig("worker", "wrk")
  ensure
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original)
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks)
  end

  def test_execute_keeps_jqs_when_job_queue_working_raises
    buffer = HireFire.configuration.buffer
    buffer.flush
    original = HireFire::Plan::ADAPTERS
    original_checks = HireFire::Plan::LIBRARY_CHECKS
    mod = stub_macro do |m|
      m.define_singleton_method(:job_queue_size) { |*_a, **_o| 9 }
      m.define_singleton_method(:job_queue_working) { |*_a| raise "wrk boom" }
    end

    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original.merge("sidekiq" => mod))
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks.merge("sidekiq" => -> { true }))

    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)

    HireFire::Plan.execute(
      "name" => "worker",
      "adapter" => "sidekiq",
      "strategy" => "jqs",
      "queues" => ["default"],
      "options" => {}
    )

    flushed = buffer.flush
    assert_equal 9, flushed.dig("worker", "jqs")&.values&.last
    assert_nil flushed.dig("worker", "wrk")
    assert_includes log.string, "wrk boom"
  ensure
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original)
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks)
  end

  def test_execute_still_samples_wrk_when_job_strategy_sample_invalid
    buffer = HireFire.configuration.buffer
    buffer.flush
    original = HireFire::Plan::ADAPTERS
    original_checks = HireFire::Plan::LIBRARY_CHECKS
    working_called = false
    mod = stub_macro do |m|
      m.define_singleton_method(:job_queue_size) { |*_a, **_o| -1 }
      m.define_singleton_method(:job_queue_working) do |*_a|
        working_called = true
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
      "options" => {}
    )

    flushed = buffer.flush
    assert_nil flushed.dig("worker", "jqs")
    assert_equal 3, flushed.dig("worker", "wrk")&.values&.last
    assert working_called, "wrk still samples when jqs is dropped"
  ensure
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original)
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks)
  end

  def test_execute_still_samples_wrk_when_job_strategy_raises
    buffer = HireFire.configuration.buffer
    buffer.flush
    original = HireFire::Plan::ADAPTERS
    original_checks = HireFire::Plan::LIBRARY_CHECKS
    working_called = false
    mod = stub_macro do |m|
      m.define_singleton_method(:job_queue_size) { |*_a, **_o| raise "jqs boom" }
      m.define_singleton_method(:job_queue_working) do |*_a|
        working_called = true
        3
      end
    end

    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original.merge("sidekiq" => mod))
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks.merge("sidekiq" => -> { true }))

    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)

    HireFire::Plan.execute(
      "name" => "worker",
      "adapter" => "sidekiq",
      "strategy" => "jqs",
      "queues" => ["default"],
      "options" => {}
    )

    flushed = buffer.flush
    assert_nil flushed.dig("worker", "jqs")
    assert_equal 3, flushed.dig("worker", "wrk")&.values&.last
    assert working_called, "wrk still samples when jqs raises"
    assert_includes log.string, "Plan sampler for"
    assert_includes log.string, "raised"
    assert_includes log.string, "jqs boom"
  ensure
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original)
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks)
  end

  def test_execute_drops_invalid_wrk_without_clearing_jqs
    buffer = HireFire.configuration.buffer
    buffer.flush
    original = HireFire::Plan::ADAPTERS
    original_checks = HireFire::Plan::LIBRARY_CHECKS
    mod = stub_macro do |m|
      m.define_singleton_method(:job_queue_size) { |*_a, **_o| 4 }
      m.define_singleton_method(:job_queue_working) { |*_a| -2 }
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
      "options" => {}
    )

    flushed = buffer.flush
    assert_equal 4, flushed.dig("worker", "jqs")&.values&.last
    assert_nil flushed.dig("worker", "wrk")
  ensure
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original)
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks)
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
      m.define_singleton_method(:job_queue_size) { |*_queues, **_options|
        called = true
        1
      }
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

    assert_equal({reuse_connection: true, amqp_url: "amqp://override.example/vhost"}, captured)
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
    assert_equal({reuse_connection: true}, HireFire::Macro::Bunny.plan_connection_options)
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

    [-1, Float::NAN, Float::INFINITY, nil, "nope", true, false].each do |bad|
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
    assert_operator log.string.scan("Sample dropped").size, :>=, 7
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

    normalized = HireFire::Plan.send(:normalize_queues, queues, name: "worker")

    assert_equal HireFire::Plan::MAX_QUEUES, normalized.size
    assert_equal "q0", normalized.first
    assert_includes log.string, "truncated"
  end

  def test_normalize_queues_skips_when_all_names_invalid
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)

    assert_nil HireFire::Plan.send(:normalize_queues, ["", "  "], name: "worker")
    assert_includes log.string, "no valid names"
  end

  def test_normalize_queues_skips_non_array
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)

    assert_nil HireFire::Plan.send(:normalize_queues, "default", name: "worker")
    assert_includes log.string, "must be an array"
  end

  def test_normalize_queues_nil_means_all_queues
    assert_equal [], HireFire::Plan.send(:normalize_queues, nil, name: "worker")
  end

  def test_around_job_queue_sample_calls_before_and_after_on_every_adapter
    original = HireFire::Plan::ADAPTERS
    events = []
    a = stub_macro do |m|
      m.define_singleton_method(:before_sample_job_queues) {
        events << [:before, :a]
        :token_a
      }
      m.define_singleton_method(:after_sample_job_queues) { |token|
        events << [:after, :a, token]
      }
    end
    b = stub_macro do |m|
      m.define_singleton_method(:before_sample_job_queues) {
        events << [:before, :b]
        :token_b
      }
      m.define_singleton_method(:after_sample_job_queues) { |token|
        events << [:after, :b, token]
      }
    end

    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, {"a" => a, "b" => b})

    result = HireFire::Plan.around_job_queue_sample {
      events << :body
      :ok
    }

    assert_equal :ok, result
    assert_equal [
      [:before, :a],
      [:before, :b],
      :body,
      [:after, :a, :token_a],
      [:after, :b, :token_b]
    ], events
  ensure
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original)
  end

  def test_around_job_queue_sample_runs_after_when_body_raises
    original = HireFire::Plan::ADAPTERS
    after_tokens = []
    mod = stub_macro do |m|
      m.define_singleton_method(:before_sample_job_queues) { :wave }
      m.define_singleton_method(:after_sample_job_queues) { |token|
        after_tokens << token
      }
    end

    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, {"x" => mod})

    assert_raises(RuntimeError) {
      HireFire::Plan.around_job_queue_sample { raise "boom" }
    }
    assert_equal [:wave], after_tokens
  ensure
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original)
  end

  def test_hooks_default_sample_wave_methods_are_noops
    mod = Module.new
    mod.extend(HireFire::Plan::Hooks)
    assert_nil mod.before_sample_job_queues
    assert_nil mod.after_sample_job_queues(:anything)
    assert_nil mod.reinit_after_fork
  end

  def test_execute_live_gate_drops_a_sample_that_returns_after_stop
    buffer = HireFire.configuration.buffer
    buffer.flush
    original = HireFire::Plan::ADAPTERS
    original_checks = HireFire::Plan::LIBRARY_CHECKS
    mod = stub_macro do |m|
      m.define_singleton_method(:job_queue_size) { |*_a, **_o| 11 }
      m.define_singleton_method(:job_queue_working) { |*_a| 3 }
    end

    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original.merge("sidekiq" => mod))
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks.merge("sidekiq" => -> { true }))

    HireFire::Plan.execute(
      {
        "name" => "worker",
        "adapter" => "sidekiq",
        "strategy" => "jqs",
        "queues" => ["default"],
        "options" => {}
      },
      -> { false }
    )

    assert_empty buffer.flush
  ensure
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original)
    HireFire::Plan.send(:remove_const, :LIBRARY_CHECKS)
    HireFire::Plan.const_set(:LIBRARY_CHECKS, original_checks)
  end

  def test_around_job_queue_sample_rescues_raising_before_hook_and_still_runs_body_and_after
    original = HireFire::Plan::ADAPTERS
    events = []
    bad = stub_macro do |m|
      m.define_singleton_method(:before_sample_job_queues) { raise "before boom" }
      m.define_singleton_method(:after_sample_job_queues) { |_token| events << :bad_after }
    end
    good = stub_macro do |m|
      m.define_singleton_method(:before_sample_job_queues) {
        events << :good_before
        :tok
      }
      m.define_singleton_method(:after_sample_job_queues) { |token| events << [:good_after, token] }
    end

    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, {"bad" => bad, "good" => good})
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)

    result = HireFire::Plan.around_job_queue_sample {
      events << :body
      :ok
    }

    assert_equal :ok, result
    assert_equal [:good_before, :body, [:good_after, :tok]], events
    refute_includes events, :bad_after
    assert_includes log.string, "before_sample_job_queues"
  ensure
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original)
  end

  def test_around_job_queue_sample_rescues_raising_after_hook_and_still_runs_other_afters
    original = HireFire::Plan::ADAPTERS
    events = []
    bad = stub_macro do |m|
      m.define_singleton_method(:before_sample_job_queues) { :bad }
      m.define_singleton_method(:after_sample_job_queues) { |_token| raise "after boom" }
    end
    good = stub_macro do |m|
      m.define_singleton_method(:before_sample_job_queues) { :good }
      m.define_singleton_method(:after_sample_job_queues) { |token| events << token }
    end

    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, {"bad" => bad, "good" => good})
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)

    assert_equal :ok, HireFire::Plan.around_job_queue_sample { :ok }
    assert_equal [:good], events
    assert_includes log.string, "after_sample_job_queues"
  ensure
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original)
  end

  def test_reinit_macros_after_fork_rescues_raising_adapter_and_continues
    original = HireFire::Plan::ADAPTERS
    called = []
    bad = stub_macro do |m|
      m.define_singleton_method(:reinit_after_fork) { raise "reinit boom" }
    end
    good = stub_macro do |m|
      m.define_singleton_method(:reinit_after_fork) { called << :good }
    end

    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, {"bad" => bad, "good" => good})
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)

    HireFire::Plan.reinit_macros_after_fork
    assert_equal [:good], called
    assert_includes log.string, "reinit_after_fork"
  ensure
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original)
  end

  def test_reinit_macros_after_fork_notifies_every_adapter
    original = HireFire::Plan::ADAPTERS
    called = []
    a = stub_macro do |m|
      m.define_singleton_method(:reinit_after_fork) { called << :a }
    end
    b = stub_macro do |m|
      m.define_singleton_method(:reinit_after_fork) { called << :b }
    end

    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, {"a" => a, "b" => b})

    HireFire::Plan.reinit_macros_after_fork
    assert_equal [:a, :b], called
  ensure
    HireFire::Plan.send(:remove_const, :ADAPTERS)
    HireFire::Plan.const_set(:ADAPTERS, original)
  end

  def test_sidekiq_sample_wave_hooks_drive_due_cache
    skip "Sidekiq not loaded" unless defined?(::Sidekiq)

    cache = HireFire::Macro::Sidekiq::DueCache
    cache.clear_all
    refute cache.sample_active?

    token = HireFire::Macro::Sidekiq.before_sample_job_queues
    assert cache.sample_active?
    refute_nil token

    HireFire::Macro::Sidekiq.after_sample_job_queues(token)
    refute cache.sample_active?
  ensure
    HireFire::Macro::Sidekiq::DueCache.clear_all if defined?(HireFire::Macro::Sidekiq::DueCache)
  end

  private

  def stub_macro
    mod = Module.new
    mod.extend(HireFire::Plan::Hooks)
    yield mod
    mod
  end
end
