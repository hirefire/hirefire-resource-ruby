# frozen_string_literal: true

require "test_helper"
require "support/own_pool"

if defined?(ActiveRecord)
  require_relative "../../env/rails_delayed_job_active_record_4/config/environment"
end

if defined?(Mongoid)
  require_relative "../../env/rails_delayed_job_mongoid_3/config/environment"
end

class HireFire::Macro::Delayed::JobTest < Minitest::Test
  include OwnPool

  LATENCY_DELTA = 2

  def setup
    super
    if defined?(ActiveRecord)
      prepare_active_record_database
    end

    if defined?(Mongoid)
      prepare_mongoid_database
    end
  end

  def test_library_loaded_is_true_when_delayed_job_gem_is_loaded
    assert HireFire::Macro::Delayed::Job.library_loaded?
    assert HireFire::Plan.any_library_loaded?
  end

  def test_job_queue_latency_without_jobs
    latency = HireFire::Macro::Delayed::Job.job_queue_latency
    assert_float_seconds latency
    assert_equal 0, latency
  end

  def test_job_queue_latency_clamps_future_run_at_to_zero
    BasicJob.delay(queue: :default).perform
    record = Delayed::Job.last
    record.update!(run_at: 1.minute.from_now, locked_at: nil, failed_at: nil)
    assert_equal 0.0, HireFire::Macro::Delayed::Job.job_queue_latency(:default)
  end

  def test_job_queue_latency_with_jobs
    BasicJob.delay(queue: :default).perform
    Timecop.freeze(1.minute.ago) { BasicJob.delay(queue: :mailer).perform }
    latency = HireFire::Macro::Delayed::Job.job_queue_latency
    assert_float_seconds latency
    assert_in_delta 60, latency, LATENCY_DELTA
    assert_in_delta 0, HireFire::Macro::Delayed::Job.job_queue_latency(:default), LATENCY_DELTA
    assert_in_delta 60, HireFire::Macro::Delayed::Job.job_queue_latency(:default, :mailer), LATENCY_DELTA
  end

  if defined?(ActiveRecord)
    def test_job_queue_latency_reads_the_oldest_run_at_and_loads_no_job
      BasicJob.delay(queue: :default).perform
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }

      HireFire::Macro::Delayed::Job.job_queue_latency(:default)

      reads = statements.grep(/delayed_jobs/)
      assert_equal 1, reads.size
      assert_match(/\ASELECT MIN\("delayed_jobs"\."run_at"\) FROM/, reads.first)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
  end

  if defined?(Mongoid)
    def test_job_queue_latency_reads_the_run_at_of_the_oldest_job_and_no_other_field
      BasicJob.delay(queue: :default).perform
      finds = []
      subscriber = Object.new
      subscriber.define_singleton_method(:started) { |event| finds << event.command if event.command_name == "find" }
      subscriber.define_singleton_method(:succeeded) { |_event| }
      subscriber.define_singleton_method(:failed) { |_event| }
      client = ::Delayed::Job.collection.client
      client.subscribe(Mongo::Monitoring::COMMAND, subscriber)

      HireFire::Macro::Delayed::Job.job_queue_latency(:default)

      assert_equal [[{"_id" => 1, "run_at" => 1}, {"run_at" => 1}, 1]], finds.map { |find| find.values_at("projection", "sort", "limit") }
    ensure
      client&.unsubscribe(Mongo::Monitoring::COMMAND, subscriber)
    end
  end

  def test_job_queue_latency_with_scheduled_job
    BasicJob.delay(queue: :default, run_at: 1.minute.from_now).perform
    BasicJob.delay(queue: :mailer, run_at: 1.minute.ago).perform
    assert_in_delta 60, HireFire::Macro::Delayed::Job.job_queue_latency, LATENCY_DELTA
    assert_in_delta 0, HireFire::Macro::Delayed::Job.job_queue_latency(:default), LATENCY_DELTA
    assert_in_delta 60, HireFire::Macro::Delayed::Job.job_queue_latency(:mailer), LATENCY_DELTA
  end

  def test_job_queue_latency_with_failed_jobs
    Timecop.freeze(1.minute.ago) { BasicJob.delay.perform.update(failed_at: Time.now) }
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_latency
  end

  def test_job_queue_size_without_jobs
    size = HireFire::Macro::Delayed::Job.job_queue_size
    assert_integer_count size
    assert_equal 0, size
  end

  def test_job_queue_size_with_jobs
    BasicJob.delay(queue: :default).perform
    BasicJob.delay(queue: :mailer).perform
    size = HireFire::Macro::Delayed::Job.job_queue_size
    assert_integer_count size
    assert_equal 2, size
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_size(:default)
    assert_equal 2, HireFire::Macro::Delayed::Job.job_queue_size(:default, :mailer)
  end

  def test_job_queue_size_with_scheduled_jobs
    BasicJob.delay(queue: :default, run_at: 1.minute.ago).perform
    BasicJob.delay(queue: :default, run_at: 1.minute.from_now).perform
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_size
  end

  def test_job_queue_size_with_failed_jobs
    BasicJob.delay.perform.update(failed_at: Time.now)
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_size
  end

  def test_job_queue_size_counts_locked_jobs_by_default
    BasicJob.delay.perform.update(locked_at: Time.now, locked_by: "worker-1")
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_size
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_size(skip_working: false)
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_size(skip_working: nil)
  end

  def test_job_queue_size_skip_working_leaves_locked_jobs_out
    BasicJob.delay.perform.update(locked_at: Time.now, locked_by: "worker-1")
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_size(skip_working: true)
  end

  def test_job_queue_latency_excludes_locked_jobs
    Timecop.freeze(1.minute.ago) do
      BasicJob.delay.perform.update(locked_at: Time.now, locked_by: "worker-1")
    end
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_latency
  end

  def test_job_queue_size_with_waiting_due_future_running_and_locked_future_jobs
    BasicJob.delay(queue: :default).perform
    BasicJob.delay(queue: :mailer, run_at: 1.minute.ago).perform
    BasicJob.delay(queue: :default, run_at: 1.minute.from_now).perform
    BasicJob.delay(queue: :other).perform.update(locked_at: Time.now, locked_by: "worker-1")
    BasicJob.delay(queue: :other, run_at: 1.minute.from_now).perform.update(locked_at: Time.now, locked_by: "worker-2")

    assert_equal 3, HireFire::Macro::Delayed::Job.job_queue_size
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_size(:default)
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_size(:mailer)
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_size(:other)
    assert_equal 2, HireFire::Macro::Delayed::Job.job_queue_size(:default, :mailer)

    assert_equal 2, HireFire::Macro::Delayed::Job.job_queue_size(skip_working: true)
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_size(:default, skip_working: true)
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_size(:mailer, skip_working: true)
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_size(:other, skip_working: true)
    assert_equal 2, HireFire::Macro::Delayed::Job.job_queue_size(:default, :mailer, skip_working: true)

    assert_equal 2, HireFire::Macro::Delayed::Job.job_queue_working(:other)
  end

  def test_job_queue_latency_ignores_locked_when_unlocked_due_exists
    Timecop.freeze(3.minutes.ago) do
      BasicJob.delay(queue: :default).perform.update(locked_at: Time.now, locked_by: "worker-1")
    end
    Timecop.freeze(1.minute.ago) { BasicJob.delay(queue: :mailer).perform }

    assert_in_delta 60, HireFire::Macro::Delayed::Job.job_queue_latency, LATENCY_DELTA
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_latency(:default)
    assert_in_delta 60, HireFire::Macro::Delayed::Job.job_queue_latency(:mailer), LATENCY_DELTA
  end

  def test_job_queue_size_with_priority_bounds
    BasicJob.delay(queue: :default).perform
    BasicJob.delay(queue: :default, priority: 1).perform
    BasicJob.delay(queue: :default, priority: 5).perform
    BasicJob.delay(queue: :mailer, priority: 10).perform

    assert_equal 4, HireFire::Macro::Delayed::Job.job_queue_size
    assert_equal 4, HireFire::Macro::Delayed::Job.job_queue_size(min_priority: nil, max_priority: nil)
    assert_equal 4, HireFire::Macro::Delayed::Job.job_queue_size(min_priority: 0)
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_size(max_priority: 0)
    assert_equal 2, HireFire::Macro::Delayed::Job.job_queue_size(min_priority: 5)
    assert_equal 3, HireFire::Macro::Delayed::Job.job_queue_size(max_priority: 5)
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_size(min_priority: 2, max_priority: 9)
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_size(min_priority: 5, max_priority: 5)
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_size(min_priority: 11)
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_size(:default, min_priority: 5)
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_size(:mailer, :other, min_priority: 5, max_priority: 10)
  end

  def test_job_queue_size_with_priority_bounds_and_locked_jobs
    BasicJob.delay(queue: :default, priority: 5).perform
    BasicJob.delay(queue: :default, priority: 5).perform.update(locked_at: Time.now, locked_by: "worker-1")
    BasicJob.delay(queue: :default, priority: 1).perform.update(locked_at: Time.now, locked_by: "worker-2")

    assert_equal 2, HireFire::Macro::Delayed::Job.job_queue_size(min_priority: 5)
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_size(min_priority: 5, skip_working: true)
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_size(max_priority: 1)
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_size(max_priority: 1, skip_working: true)
  end

  def test_job_queue_latency_with_priority_bounds
    Timecop.freeze(3.minutes.ago) { BasicJob.delay(queue: :default, priority: 1).perform }
    Timecop.freeze(2.minutes.ago) { BasicJob.delay(queue: :default, priority: 5).perform }
    Timecop.freeze(1.minute.ago) { BasicJob.delay(queue: :mailer, priority: 10).perform }

    assert_in_delta 180, HireFire::Macro::Delayed::Job.job_queue_latency, LATENCY_DELTA
    assert_in_delta 180, HireFire::Macro::Delayed::Job.job_queue_latency(min_priority: nil, max_priority: nil), LATENCY_DELTA
    assert_in_delta 120, HireFire::Macro::Delayed::Job.job_queue_latency(min_priority: 5), LATENCY_DELTA
    assert_in_delta 180, HireFire::Macro::Delayed::Job.job_queue_latency(max_priority: 5), LATENCY_DELTA
    assert_in_delta 120, HireFire::Macro::Delayed::Job.job_queue_latency(min_priority: 2, max_priority: 9), LATENCY_DELTA
    assert_in_delta 60, HireFire::Macro::Delayed::Job.job_queue_latency(min_priority: 6), LATENCY_DELTA
    assert_in_delta 60, HireFire::Macro::Delayed::Job.job_queue_latency(:mailer, max_priority: 10), LATENCY_DELTA
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_latency(min_priority: 11)
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_latency(max_priority: 0)
  end

  def test_raises_when_no_mapper_is_detected
    ::Delayed::Job.stubs(:ancestors).returns([Object])

    error = assert_raises HireFire::Macro::Delayed::Job::MapperNotDetectedError do
      HireFire::Macro::Delayed::Job.job_queue_size
    end
    assert_equal "Unable to detect the appropriate mapper.", error.message
  end

  def test_job_queue_latency_of_a_job_that_is_due_at_this_moment_is_zero
    Timecop.freeze(Time.at(Time.now.to_i)) do
      BasicJob.delay(queue: :default, run_at: Time.now).perform

      assert_equal 0.0, HireFire::Macro::Delayed::Job.job_queue_latency(:default)
    end
  end

  def test_deprecated_queue_method
    BasicJob.delay(queue: :default).perform

    if defined?(ActiveRecord)
      assert_equal 1, HireFire::Macro::Delayed::Job.queue(:default, mapper: :active_record)
    elsif defined?(Mongoid)
      assert_equal 1, HireFire::Macro::Delayed::Job.queue(:default, mapper: :mongoid)
    end
  end

  def test_deprecated_queue_method_counts_locked_jobs
    BasicJob.delay(queue: :default).perform
    BasicJob.delay(queue: :default).perform.update(locked_at: Time.now, locked_by: "worker-1")

    mapper = defined?(ActiveRecord) ? :active_record : :mongoid

    assert_equal 2, HireFire::Macro::Delayed::Job.queue(:default, mapper: mapper)
  end

  def test_deprecated_queue_method_with_priority_range
    BasicJob.delay(queue: :default, priority: 1).perform
    BasicJob.delay(queue: :default, priority: 5).perform

    mapper = defined?(ActiveRecord) ? :active_record : :mongoid

    assert_equal 1, HireFire::Macro::Delayed::Job.queue(mapper: mapper, min_priority: 3)
    assert_equal 1, HireFire::Macro::Delayed::Job.queue(mapper: mapper, max_priority: 3)
    assert_equal 2, HireFire::Macro::Delayed::Job.queue(mapper: mapper, min_priority: 0, max_priority: 10)
  end

  def test_deprecated_queue_method_reads_options_from_inside_a_list_of_queues
    BasicJob.delay(queue: :default, priority: 1).perform
    BasicJob.delay(queue: :default, priority: 5).perform
    BasicJob.delay(queue: :mailer, priority: 5).perform

    assert_equal 1, HireFire::Macro::Delayed::Job.queue([:default, {min_priority: 3}])
    assert_equal 2, HireFire::Macro::Delayed::Job.queue([[:default, :mailer], {min_priority: 3}])
  end

  def test_deprecated_queue_method_accepts_and_drops_the_mapper
    BasicJob.delay(queue: :default).perform

    assert_equal 1, HireFire::Macro::Delayed::Job.queue(:default)
    assert_equal 1, HireFire::Macro::Delayed::Job.queue(:default, mapper: :active_record)
    assert_equal 1, HireFire::Macro::Delayed::Job.queue(:default, mapper: :active_record_2)
    assert_equal 1, HireFire::Macro::Delayed::Job.queue(:default, mapper: :mongoid)
  end

  def test_deprecated_queue_returns_what_job_queue_size_returns_for_each_call_shape
    BasicJob.delay(queue: :default, priority: 1).perform
    BasicJob.delay(queue: :default, priority: 5).perform.update(locked_at: Time.now, locked_by: "worker-1")
    BasicJob.delay(queue: :mailer, priority: 10).perform
    BasicJob.delay(queue: :mailer, run_at: 1.minute.from_now).perform
    macro = HireFire::Macro::Delayed::Job
    mapper = defined?(ActiveRecord) ? :active_record : :mongoid

    assert_equal 3, macro.queue(mapper: mapper)
    assert_equal macro.job_queue_size, macro.queue(mapper: mapper)
    assert_equal macro.job_queue_size(:default), macro.queue(:default, mapper: mapper)
    assert_equal macro.job_queue_size(:default), macro.queue("default", {mapper: mapper})
    assert_equal macro.job_queue_size(:default, :mailer), macro.queue([:default, ["mailer"]], mapper: mapper)
    assert_equal macro.job_queue_size(min_priority: 5), macro.queue(mapper: mapper, min_priority: 5)
    assert_equal macro.job_queue_size(max_priority: 5), macro.queue(mapper: mapper, max_priority: 5)
    assert_equal macro.job_queue_size(:mailer, min_priority: 2, max_priority: 10),
      macro.queue(:mailer, mapper: mapper, min_priority: 2, max_priority: 10)
  end

  def test_deprecated_queue_treats_an_explicit_nil_priority_bound_as_no_bound
    BasicJob.delay(queue: :default, priority: 1).perform
    BasicJob.delay(queue: :default, priority: 5).perform
    mapper = defined?(ActiveRecord) ? :active_record : :mongoid

    assert_equal 2, HireFire::Macro::Delayed::Job.queue(mapper: mapper, min_priority: nil)
    assert_equal 2, HireFire::Macro::Delayed::Job.queue(mapper: mapper, max_priority: nil)
    assert_equal 1, HireFire::Macro::Delayed::Job.queue(mapper: mapper, min_priority: nil, max_priority: 3)
  end

  def test_deprecated_queue_passes_on_only_the_options_the_1_x_method_read
    HireFire::Macro::Delayed::Job.expects(:job_queue_size).with(:default, "mailer", min_priority: 1, max_priority: 5).returns(7)

    assert_equal 7, HireFire::Macro::Delayed::Job.queue(
      :default, "mailer", mapper: :active_record, min_priority: 1, max_priority: 5, skip_working: true, bogus: 1
    )
  end

  def test_job_queue_working_idle_is_zero
    working = HireFire::Macro::Delayed::Job.job_queue_working
    assert_integer_count working
    assert_equal 0, working
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_working(:default)
  end

  def test_job_queue_working_counts_in_flight_and_filters_queues
    BasicJob.delay(queue: :default).perform.update(locked_at: Time.now, locked_by: "worker-1")
    BasicJob.delay(queue: :mailer).perform.update(locked_at: Time.now, locked_by: "worker-2")

    working = HireFire::Macro::Delayed::Job.job_queue_working
    assert_integer_count working
    assert_equal 2, working
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_working(:default)
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_working(:mailer)
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_working(:critical)
    assert_equal 2, HireFire::Macro::Delayed::Job.job_queue_working(:default, :mailer)
  end

  if Delayed::Job.respond_to?(:connection_pool)
    def test_a_sample_leaves_the_primary_pool_alone_when_the_jobs_have_their_own_pool
      checkouts = primary_checkouts_while_on_its_own_pool(Delayed::Job) do
        HireFire::Macro::Delayed::Job.job_queue_size
        HireFire::Macro::Delayed::Job.job_queue_size(skip_working: true)
        HireFire::Macro::Delayed::Job.job_queue_latency
        HireFire::Macro::Delayed::Job.job_queue_working
      end

      assert_equal 0, checkouts
    end
  end

  def test_job_queue_working_excludes_unlocked_and_failed
    BasicJob.delay(queue: :default).perform
    BasicJob.delay(queue: :mailer).perform.update(failed_at: Time.now, locked_at: Time.now, locked_by: "worker-1")
    BasicJob.delay(queue: :other).perform.update(locked_at: Time.now, locked_by: "worker-2")

    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_working
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_working(:default)
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_working(:mailer)
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_working(:other)
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_size(:default)
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_size(:mailer)
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_size(:other)
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_size(:other, skip_working: true)
  end

  def test_a_job_locked_longer_than_max_run_time_counts_as_waiting
    expired = Time.now - Delayed::Worker.max_run_time - 60
    BasicJob.delay(queue: :default, run_at: 10.minutes.ago).perform.update(locked_at: expired, locked_by: "a worker that was killed")

    if Delayed::Job.respond_to?(:ready_to_run)
      assert_equal 1, Delayed::Job.ready_to_run("another worker", Delayed::Worker.max_run_time).count
    end
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_working(:default)
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_size(:default, skip_working: true)
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_size(:default)
    assert_in_delta 600, HireFire::Macro::Delayed::Job.job_queue_latency(:default), LATENCY_DELTA
  end

  def test_a_job_locked_within_max_run_time_counts_as_working
    fresh = Time.now - Delayed::Worker.max_run_time + 60
    BasicJob.delay(queue: :default, run_at: 10.minutes.ago).perform.update(locked_at: fresh, locked_by: "worker-1")

    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_working(:default)
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_size(:default, skip_working: true)
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_size(:default)
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_latency(:default)
  end

  def test_plan_execute_delayed_job_jqs_counts_running_jobs_and_samples_no_wrk
    HireFire.configure { |c| c.logger = Logger.new(File::NULL) }
    buffer = HireFire.configuration.buffer
    buffer.flush

    BasicJob.delay(queue: :default).perform.update(locked_at: Time.now, locked_by: "worker-1")
    BasicJob.delay(queue: :default).perform

    sample_plan(
      "name" => "worker",
      "adapter" => "delayed_job",
      "strategy" => "jqs",
      "queues" => ["default"],
      "options" => {}
    )

    flushed = buffer.flush
    assert flushed["worker"], "plan must buffer under process name"
    assert flushed["worker"]["jqs"], "plan must sample jqs"
    assert_nil flushed["worker"]["wrk"], "plan must sample no wrk when the size holds the running jobs"

    jqs_value = flushed["worker"]["jqs"].values.last
    working = HireFire::Macro::Delayed::Job.job_queue_working(:default)
    assert_kind_of Numeric, jqs_value
    assert_equal HireFire::Macro::Delayed::Job.job_queue_size(:default), jqs_value
    assert_operator working, :>, 0
    assert_equal jqs_value, HireFire::Macro::Delayed::Job.job_queue_size(:default, skip_working: true) + working
  end

  def test_plan_execute_skip_working_true_leaves_running_jobs_out_and_still_records_wrk
    HireFire.configure { |c| c.logger = Logger.new(File::NULL) }
    buffer = HireFire.configuration.buffer
    buffer.flush

    BasicJob.delay(queue: :default).perform.update(locked_at: Time.now, locked_by: "worker-1")
    BasicJob.delay(queue: :default).perform

    sample_plan(
      "name" => "worker",
      "adapter" => "delayed_job",
      "strategy" => "jqs",
      "queues" => ["default"],
      "options" => {"skip_working" => true}
    )

    flushed = buffer.flush
    assert_equal 1, flushed.dig("worker", "jqs")&.values&.last
    assert_equal 1, flushed.dig("worker", "wrk")&.values&.last
  end

  def test_plan_execute_delayed_job_jql_also_samples_wrk
    HireFire.configure { |c| c.logger = Logger.new(File::NULL) }
    buffer = HireFire.configuration.buffer
    buffer.flush

    BasicJob.delay(queue: :default).perform.update(locked_at: Time.now, locked_by: "worker-1")

    sample_plan(
      "name" => "worker",
      "adapter" => "delayed_job",
      "strategy" => "jql",
      "queues" => ["default"],
      "options" => {}
    )

    flushed = buffer.flush
    assert flushed.dig("worker", "jql")
    assert_equal 1, flushed.dig("worker", "wrk")&.values&.last
  end

  def test_plan_execute_delayed_job_empty_queues_samples_all_wrk
    HireFire.configure { |c| c.logger = Logger.new(File::NULL) }
    buffer = HireFire.configuration.buffer
    buffer.flush

    BasicJob.delay(queue: :default).perform.update(locked_at: Time.now, locked_by: "worker-1")
    BasicJob.delay(queue: :mailer).perform.update(locked_at: Time.now, locked_by: "worker-2")

    sample_plan(
      "name" => "worker",
      "adapter" => "delayed_job",
      "strategy" => "jqs",
      "queues" => [],
      "options" => {"skip_working" => true}
    )

    flushed = buffer.flush
    assert_equal 2, flushed.dig("worker", "wrk")&.values&.last
    assert_equal HireFire::Macro::Delayed::Job.job_queue_working, flushed.dig("worker", "wrk")&.values&.last
  end

  private

  def prepare_active_record_database
    db_config = Rails.configuration.database_configuration[Rails.env]

    begin
      ActiveRecord::Base.establish_connection(db_config)
      ActiveRecord::Migration.verbose = false
      ActiveRecord::MigrationContext.new(Rails.root.join("db/migrate").to_s).migrate
    rescue ActiveRecord::NoDatabaseError
      ActiveRecord::Tasks::DatabaseTasks.create(db_config)
      retry
    end

    Delayed::Job.delete_all
  end

  def prepare_mongoid_database
    Delayed::Job.delete_all
  end
end
