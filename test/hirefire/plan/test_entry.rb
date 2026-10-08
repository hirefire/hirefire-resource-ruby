# frozen_string_literal: true

require "test_helper"

class HireFire::Plan::EntryTest < Minitest::Test
  def entry(fields = {})
    HireFire::Plan::Entry.new({"name" => "worker", "strategy" => "jqs", "adapter" => "sidekiq", "queues" => ["default"]}.merge(fields))
  end

  def loaded(samples = {job_queue_size: 5, job_queue_latency: 1.5})
    plan_adapter(samples)
  end

  def test_an_entry_without_an_adapter_is_local_and_never_sampleable_by_an_adapter
    [nil, ""].each do |adapter|
      local = entry("adapter" => adapter)

      assert local.local?
      refute local.sampleable?
      assert_nil local.problem
    end
    refute entry.local?
  end

  def test_a_local_entry_with_a_strategy_other_than_latency_or_size_is_a_problem
    local = entry("adapter" => nil, "strategy" => "rpm")

    assert_equal :unknown_strategy, local.problem
    assert_equal 'Unknown plan strategy "rpm" for "worker". Entry skipped.', local.problem_message
  end

  def test_an_adapter_the_client_does_not_know_is_a_problem
    unknown = entry("adapter" => "nope")

    assert_equal :unknown_adapter, unknown.problem
    assert_equal 'Unknown plan adapter "nope" for "worker". Entry skipped.', unknown.problem_message
    refute unknown.sampleable?
  end

  def test_an_adapter_whose_library_is_not_loaded_is_a_problem
    with_plan_adapters("sidekiq" => plan_adapter({}).tap { |adapter| adapter.define_singleton_method(:library_loaded?) { false } }) do
      assert_equal :unloaded_adapter, entry.problem
      assert_equal 'Plan adapter "sidekiq" for "worker" is not loaded in this process. Entry skipped.', entry.problem_message
    end
  end

  def test_a_strategy_the_adapter_does_not_take_is_a_problem
    size_only = loaded.tap { |adapter| adapter.extend(HireFire::Plan::SizeOnly) }
    with_plan_adapters("sidekiq" => loaded, "bunny" => size_only) do
      assert_equal :unsupported_strategy, entry("strategy" => "rpm").problem
      assert_equal :unsupported_strategy, entry("adapter" => "bunny", "strategy" => "jql").problem
      assert_equal 'Plan adapter "bunny" does not support strategy "jql" for "worker". Entry skipped.',
        entry("adapter" => "bunny", "strategy" => "jql").problem_message
      assert_nil entry("adapter" => "bunny", "strategy" => "jqs").problem
      assert_nil entry("strategy" => "jql").problem
    end
  end

  def test_an_adapter_that_needs_queue_names_and_gets_none_is_a_problem
    naming = loaded.tap { |adapter| adapter.define_singleton_method(:queues_required?) { true } }
    with_plan_adapters("bunny" => naming) do
      [nil, [], [" ", ""], "default", ["x" * 129]].each do |queues|
        required = entry("adapter" => "bunny", "queues" => queues)

        assert_equal :queues_required, required.problem, "#{queues.inspect} was accepted"
        assert_equal 'Plan adapter "bunny" for "worker" requires named queues. Entry skipped.', required.problem_message
      end
      assert_nil entry("adapter" => "bunny", "queues" => ["default"]).problem
    end
  end

  def test_a_queue_list_that_is_not_a_list_or_holds_no_valid_name_is_a_problem
    with_plan_adapters("sidekiq" => loaded) do
      assert_equal :queues_not_a_list, entry("queues" => "default").problem
      assert_equal 'Plan queues for "worker" must be an array. Entry skipped.', entry("queues" => "default").problem_message
      assert_equal :queues_not_a_list, entry("queues" => {"a" => 1}).problem
      assert_equal :no_valid_queues, entry("queues" => ["", "  ", "x" * 129]).problem
      assert_equal 'Plan queue list for "worker" had no valid names. Entry skipped.', entry("queues" => [""]).problem_message
      assert_nil entry("queues" => nil).problem
      assert_nil entry("queues" => []).problem
    end
  end

  def test_an_entry_without_a_problem_is_sampleable
    with_plan_adapters("sidekiq" => loaded) do
      assert entry.sampleable?
      assert entry("queues" => nil).sampleable?
    end
  end

  def test_queue_names_are_stripped_and_limited_in_length_and_number
    assert_equal 64, HireFire::Plan::MAX_QUEUES
    assert_equal 128, HireFire::Plan::MAX_QUEUE_NAME_BYTES
    names = [" default ", "", :mailer, "x" * 128, "x" * 129, 7]

    assert_equal ["default", "mailer", "x" * 128, "7"], entry("queues" => names).queues
    refute entry("queues" => names).truncated?

    exact = entry("queues" => Array.new(64) { |index| "q#{index}" })
    over = entry("queues" => Array.new(65) { |index| "q#{index}" })
    assert_equal 64, exact.queues.size
    refute exact.truncated?
    assert_equal Array.new(64) { |index| "q#{index}" }, over.queues
    assert over.truncated?
  end

  def test_the_call_passes_the_queues_and_the_options_the_adapter_allows
    calls = []
    adapter = plan_adapter({})
    adapter.define_singleton_method(:job_queue_size) do |*queues, **options|
      calls << [queues, options]
      9
    end
    adapter.define_singleton_method(:plan_options) { |strategy, options| extract_plan_options(strategy, options, "jqs" => {"skip_working" => :boolean}) }
    adapter.define_singleton_method(:plan_connection_options) { {reuse_connection: true} }

    with_plan_adapters("sidekiq" => adapter) do
      result = entry("queues" => ["default", "mailer"], "options" => {"skip_working" => true, "server" => true}).call

      assert_equal 9, result
      assert_equal [[["default", "mailer"], {skip_working: true, reuse_connection: true}]], calls
    end
  end

  def test_the_call_uses_the_latency_method_for_a_latency_entry
    with_plan_adapters("sidekiq" => loaded) do
      assert_equal 1.5, entry("strategy" => "jql").call
      assert_equal 5, entry("strategy" => "jqs").call
    end
  end

  def test_working_is_sampled_for_latency_and_for_a_size_that_leaves_running_jobs_out
    counting = loaded(job_queue_size: 5, job_queue_latency: 1.5, job_queue_working: 3)
    counting.define_singleton_method(:plan_options) { |strategy, options| extract_plan_options(strategy, options, "jqs" => {"skip_working" => :boolean}) }

    with_plan_adapters("sidekiq" => counting, "bunny" => loaded) do
      assert entry("strategy" => "jql").working?
      assert entry("options" => {"skip_working" => true}).working?
      refute entry.working?
      refute entry("options" => {"skip_working" => false}).working?
      refute entry("adapter" => "bunny", "strategy" => "jql").working?
      assert_equal 3, entry("strategy" => "jql").working
    end
  end

  def test_the_key_tells_entries_apart_by_name_adapter_and_strategy
    assert_equal ["worker", "sidekiq", "jqs"], entry.key
    refute_equal entry.key, entry("strategy" => "jql").key
    refute_equal entry.key, entry("name" => "mailer").key
    assert_equal ["worker", "", "jqs"], entry("adapter" => nil).key
  end

  def test_every_planned_adapter_answers_whether_its_library_is_loaded
    assert_equal %w[sidekiq solid_queue good_job que queue_classic delayed_job resque bunny], HireFire::Plan::ADAPTERS.keys
    HireFire::Plan::ADAPTERS.each_value do |macro|
      assert_includes [true, false], macro.library_loaded?
    end
  end
end
