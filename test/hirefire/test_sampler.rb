# frozen_string_literal: true

require "test_helper"

class HireFire::SamplerTest < Minitest::Test
  def setup
    super
    @log = StringIO.new
    HireFire.configuration.logger = Logger.new(@log)
  end

  def buffer
    HireFire.configuration.buffer
  end

  def local(name, strategy = "jql")
    {"name" => name, "strategy" => strategy}
  end

  def planned(name, fields = {})
    {"name" => name, "strategy" => "jqs", "adapter" => "sidekiq", "queues" => ["default"]}.merge(fields)
  end

  def test_a_local_entry_is_sampled_by_the_sampler_of_that_name
    HireFire.configuration.dyno(:worker) { 42 }
    HireFire.configuration.dyno(:mailer) { 18 }

    sample_plan(local("worker", "jql"), local("mailer", "jqs"))

    data = buffer.flush
    assert_equal [42], data["worker"]["jql"].values
    assert_equal [18], data["mailer"]["jqs"].values
  end

  def test_a_local_entry_is_reported_under_the_name_the_plan_spells
    HireFire.configuration.dyno(:Worker) { 4 }

    sample_plan(local("worker", "jqs"))

    assert_equal ["worker"], buffer.flush.keys
  end

  def test_the_latest_sample_of_a_second_wins
    values = [5, 9].each
    HireFire.configuration.dyno(:worker) { values.next }

    2.times { sample_plan(local("worker")) }

    assert_equal [9], buffer.flush["worker"]["jql"].values
  end

  def test_zero_and_fractions_and_other_numeric_classes_are_recorded_as_numbers
    require "bigdecimal"
    HireFire.configuration.dyno(:zero) { 0 }
    HireFire.configuration.dyno(:decimal) { BigDecimal("1.5") }
    HireFire.configuration.dyno(:rational) { Rational(1, 4) }

    sample_plan(local("zero"), local("decimal"), local("rational"))

    data = buffer.flush
    assert_equal [0], data["zero"]["jql"].values
    assert_equal [1.5], data["decimal"]["jql"].values
    assert_equal [0.25], data["rational"]["jql"].values
    assert_kind_of Float, data["decimal"]["jql"].values.first
  end

  def test_a_value_that_is_not_a_number_from_zero_up_is_dropped_and_named_in_the_log
    values = ["10", nil, -1, Float::INFINITY, Float::NAN, true].each
    HireFire.configuration.dyno(:worker) { values.next }

    6.times { sample_plan(local("worker")) }

    assert_empty buffer.flush
    assert_equal 6, @log.string.scan('The sampler for "worker" returned').size
    assert_includes @log.string, 'returned String("10"), expected a non-negative number. Sample dropped.'
    assert_includes @log.string, 'Integer("-1")'
    assert_includes @log.string, 'NilClass("")'
  end

  def test_a_sampler_that_raises_is_logged_without_its_credentials_and_the_next_entry_is_sampled
    HireFire.configuration.dyno(:Worker) { raise "redis://user:secret@localhost:6379/0 down" }
    HireFire.configuration.dyno(:mailer) { 18 }

    sample_plan(local("worker"), local("mailer"))

    assert_equal ["mailer"], buffer.flush.keys
    assert_includes @log.string, 'The sampler for "worker" raised RuntimeError: redis://***@localhost:6379/0 down'
    refute_includes @log.string, "secret"
  end

  def test_a_value_whose_text_cannot_be_read_is_named_by_its_class
    unreadable = Class.new do
      def self.name = "Unreadable"

      def to_s = raise("no text")
    end
    HireFire.configuration.dyno(:worker) { unreadable.new }

    sample_plan(local("worker"))

    assert_includes @log.string, 'The sampler for "worker" returned Unreadable, expected a non-negative number. Sample dropped.'
  end

  def test_an_adapter_whose_plan_hook_raises_is_logged_and_the_next_entry_is_sampled
    broken = plan_adapter(job_queue_size: 1)
    broken.define_singleton_method(:library_loaded?) { raise "redis://user:secret@localhost:6379/0 hook boom" }

    with_plan_adapters("resque" => broken, "sidekiq" => plan_adapter(job_queue_size: 7)) do
      sample_plan(planned("worker", "adapter" => "resque"), planned("mailer"))
    end

    assert_equal ["mailer"], buffer.flush.keys
    assert_includes @log.string, '[HireFire] Plan sampler for "worker" raised RuntimeError: redis://***@localhost:6379/0 hook boom'
  end

  def test_a_logger_that_raises_does_not_end_the_round
    HireFire.configuration.dyno(:worker) { raise "Redis down" }
    HireFire.configuration.dyno(:mailer) { 18 }
    broken = Object.new
    broken.define_singleton_method(:error) { |*| raise IOError, "closed stream" }
    HireFire.configuration.logger = broken

    sample_plan(local("worker"), local("mailer"))

    assert_equal ["mailer"], buffer.flush.keys
  end

  def test_a_sample_that_returns_after_the_round_is_no_longer_live_is_dropped
    HireFire.configuration.dyno(:worker) { 9 }
    live = [true, false].each

    sample_plan(local("worker")) { live.next }

    assert_empty buffer.flush
  end

  def test_a_round_that_is_not_live_samples_no_entry
    calls = 0
    HireFire.configuration.dyno(:worker) { calls += 1 }

    trace = sample_plan(local("worker")) { false }

    assert_equal 0, calls
    assert_empty trace["ops"]
  end

  def test_samples_go_to_the_buffer_of_the_configuration_the_sampler_was_given
    other = HireFire::Configuration.new
    other.dyno(:worker) { 7 }

    HireFire::Sampler.new(other).round([local("worker")], -> { true })

    assert_empty buffer.flush
    assert_equal [7], other.buffer.flush.dig("worker", "jql").values
  end

  def test_a_local_entry_without_a_sampler_of_its_name_warns_once_when_other_samplers_exist
    HireFire.configuration.dyno(:worker) { 1 }
    sampler = HireFire::Sampler.new(HireFire.configuration)

    3.times { sampler.round([local("wroker"), local("worker")], -> { true }) }

    assert_equal 1, @log.string.scan('No config.dyno sampler is named "wroker", so this process samples nothing for it.').size
    assert_match(/WARN/, @log.string)
    assert_equal ["worker"], buffer.flush.keys
  end

  def test_a_local_entry_without_a_sampler_is_silent_in_a_process_that_has_no_sampler_at_all
    sample_plan(local("worker"))

    assert_empty @log.string
    assert_empty buffer.flush
  end

  def test_an_entry_with_a_problem_is_logged_once_per_entry_and_never_sampled
    sampler = HireFire::Sampler.new(HireFire.configuration)
    plan = [planned("worker", "adapter" => "nope"), planned("mailer", "adapter" => "nope"), local("worker", "rpm")]

    3.times { sampler.round(plan, -> { true }) }

    assert_equal 1, @log.string.scan('Unknown plan adapter "nope" for "worker". Entry skipped.').size
    assert_equal 1, @log.string.scan('Unknown plan adapter "nope" for "mailer". Entry skipped.').size
    assert_equal 1, @log.string.scan('Unknown plan strategy "rpm" for "worker". Entry skipped.').size
    assert_equal 3, @log.string.scan("ERROR").size
    assert_empty buffer.flush
  end

  def test_a_new_sampler_logs_a_problem_again
    2.times { sample_plan(planned("worker", "adapter" => "nope")) }

    assert_equal 2, @log.string.scan("Unknown plan adapter").size
  end

  def test_an_adapter_entry_records_its_strategy_and_the_running_jobs_when_they_apply
    adapter = plan_adapter(job_queue_size: 11, job_queue_latency: 2.5, job_queue_working: 3)
    adapter.define_singleton_method(:plan_options) { |strategy, options| extract_plan_options(strategy, options, "jqs" => {"skip_working" => :boolean}) }

    with_plan_adapters("sidekiq" => adapter) do
      sample_plan(
        planned("size"),
        planned("waiting", "options" => {"skip_working" => true}),
        planned("latency", "strategy" => "jql")
      )
    end

    data = buffer.flush.transform_values { |metrics| metrics.transform_values { |series| series.values.first } }
    assert_equal({"size" => {"jqs" => 11}, "waiting" => {"jqs" => 11, "wrk" => 3}, "latency" => {"jql" => 2.5, "wrk" => 3}}, data)
  end

  def test_an_adapter_that_raises_or_returns_no_number_is_logged_and_the_running_jobs_are_still_recorded
    raising = plan_adapter(job_queue_latency: -> { raise LoadError, "cannot load such file -- sidekiq/api" }, job_queue_working: 4)
    invalid = plan_adapter(job_queue_latency: "many", job_queue_working: -> { raise "working boom" })

    with_plan_adapters("sidekiq" => raising, "resque" => invalid) do
      sample_plan(planned("worker", "strategy" => "jql"), planned("mailer", "strategy" => "jql", "adapter" => "resque"))
    end

    assert_equal({"worker" => ["wrk"]}, buffer.flush.transform_values(&:keys))
    assert_includes @log.string, 'Plan sampler for "worker" raised LoadError: cannot load such file -- sidekiq/api'
    assert_includes @log.string, 'Plan sampler for "mailer" returned String("many"), expected a non-negative number. Sample dropped.'
    assert_includes @log.string, 'Plan working sampler for "mailer" raised RuntimeError: working boom'
  end

  def test_an_adapter_entry_wins_over_a_local_sampler_of_the_same_name_and_says_so_once
    calls = 0
    HireFire.configuration.dyno(:worker) { calls += 1 }
    sampler = HireFire::Sampler.new(HireFire.configuration)

    with_plan_adapters("sidekiq" => plan_adapter(job_queue_size: 11)) do
      2.times { sampler.round([planned("worker")], -> { true }) }
    end

    assert_equal 0, calls
    assert_equal [11], buffer.flush["worker"]["jqs"].values
    assert_equal 1, @log.string.scan('A HireFire UI adapter is configured for "worker", so config.dyno("worker") with a local sampler is ignored.').size
  end

  def test_a_queue_list_over_the_limit_is_cut_and_logged_once_with_the_name_of_the_entry
    seen = []
    adapter = plan_adapter({})
    adapter.define_singleton_method(:job_queue_size) do |*queues, **_options|
      seen << queues.size
      1
    end
    sampler = HireFire::Sampler.new(HireFire.configuration)

    with_plan_adapters("sidekiq" => adapter) do
      2.times { sampler.round([planned("worker", "queues" => Array.new(70) { |index| "q#{index}" })], -> { true }) }
    end

    assert_equal [64, 64], seen
    assert_equal 1, @log.string.scan('Plan queue list for "worker" truncated to 64 names.').size
  end

  def test_the_round_returns_one_timed_operation_per_entry_it_reached
    HireFire.configuration.dyno(:worker) { 1 }

    trace = sample_plan(local("worker"), planned("mailer", "adapter" => "nope", "options" => {"a" => 1}))

    assert_kind_of Float, trace["wave_ms"]
    assert_equal [nil, "nope"], trace["ops"].map { |op| op["adapter"] }
    assert_equal [[], ["default"]], trace["ops"].map { |op| op["queues"] }
    assert_equal [{}, {"a" => 1}], trace["ops"].map { |op| op["options"] }
    assert(trace["ops"].all? { |op| op["ms"].is_a?(Float) })
  end

  def test_the_round_logs_its_timings_when_verbose_is_set
    HireFire.configuration.dyno(:worker) { 1 }

    sample_plan(local("worker"))
    assert_empty @log.string

    ENV["HIREFIRE_VERBOSE"] = "1"
    sample_plan(local("worker"))
    assert_includes @log.string, "sample_job_queues wave_ms="
    assert_includes @log.string, "ops=1"
  end

  def test_a_process_can_sample_a_plan_when_it_has_a_sampler_or_can_run_one_of_the_entries
    sampler = HireFire::Sampler.new(HireFire.configuration)

    refute sampler.can_sample?([])
    refute sampler.can_sample?([local("worker")])
    refute sampler.can_sample?([planned("worker", "adapter" => "nope")])
    with_plan_adapters("sidekiq" => plan_adapter(job_queue_size: 1)) do
      assert sampler.can_sample?([planned("worker", "adapter" => "nope"), planned("mailer")])
      refute sampler.can_sample?([planned("mailer", "strategy" => "rpm")])
    end

    HireFire.configuration.dyno(:worker) { 1 }
    assert sampler.can_sample?([])
    assert sampler.can_sample?([planned("worker", "adapter" => "nope")])
  end

  def test_the_hooks_of_every_adapter_run_around_the_round_and_after_an_entry_that_raises_any_exception
    events = []
    adapter = plan_adapter(job_queue_size: -> { raise Exception, "outside every rescue" }) # standard:disable Lint/RaiseException
    adapter.define_singleton_method(:before_sample_job_queues) { events << :before }
    adapter.define_singleton_method(:after_sample_job_queues) { |_token| events << :after }

    with_plan_adapters("sidekiq" => adapter) do
      assert_raises(Exception) { sample_plan(planned("worker")) }
    end

    assert_equal %i[before after], events
  end
end
