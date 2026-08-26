# frozen_string_literal: true

require "test_helper"

if defined?(ActiveRecord)
  require_relative "../../env/rails_delayed_job_active_record_4/config/environment"
end

if defined?(Mongoid)
  require_relative "../../env/rails_delayed_job_mongoid_3/config/environment"
end

class HireFire::Macro::Delayed::JobTest < Minitest::Test
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
    assert HireFire::Plan.library_loaded?("delayed_job")
    assert HireFire::Plan.executable?("delayed_job")
    assert HireFire::Plan.any_allowlisted_job_queue_library_loaded?
  end

  def test_job_queue_latency_without_jobs
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_latency
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
    assert_in_delta 60, HireFire::Macro::Delayed::Job.job_queue_latency, LATENCY_DELTA
    assert_in_delta 0, HireFire::Macro::Delayed::Job.job_queue_latency(:default), LATENCY_DELTA
    assert_in_delta 60, HireFire::Macro::Delayed::Job.job_queue_latency(:default, :mailer), LATENCY_DELTA
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
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_size
  end

  def test_job_queue_size_with_jobs
    BasicJob.delay(queue: :default).perform
    BasicJob.delay(queue: :mailer).perform
    assert_equal 2, HireFire::Macro::Delayed::Job.job_queue_size
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

  def test_job_queue_size_excludes_locked_jobs
    BasicJob.delay.perform.update(locked_at: Time.now, locked_by: "worker-1")
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_size
  end

  def test_job_queue_latency_excludes_locked_jobs
    Timecop.freeze(1.minute.ago) do
      BasicJob.delay.perform.update(locked_at: Time.now, locked_by: "worker-1")
    end
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_latency
  end

  def test_job_queue_size_counts_due_unlocked_only_with_locked_and_future_present
    BasicJob.delay(queue: :default).perform
    BasicJob.delay(queue: :mailer).perform
    BasicJob.delay(queue: :default, run_at: 1.minute.from_now).perform
    BasicJob.delay(queue: :other).perform.update(locked_at: Time.now, locked_by: "worker-1")

    assert_equal 2, HireFire::Macro::Delayed::Job.job_queue_size
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_size(:default)
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_size(:mailer)
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_size(:other)
    assert_equal 2, HireFire::Macro::Delayed::Job.job_queue_size(:default, :mailer)
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

  def test_raises_when_no_mapper_is_detected
    ::Delayed::Job.stubs(:ancestors).returns([Object])

    assert_raises HireFire::Macro::Delayed::Job::MapperNotDetectedError do
      HireFire::Macro::Delayed::Job.job_queue_size
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

  def test_deprecated_queue_method_excludes_locked_jobs
    BasicJob.delay(queue: :default).perform
    BasicJob.delay(queue: :default).perform.update(locked_at: Time.now, locked_by: "worker-1")

    mapper = defined?(ActiveRecord) ? :active_record : :mongoid

    assert_equal 1, HireFire::Macro::Delayed::Job.queue(:default, mapper: mapper)
  end

  def test_deprecated_queue_method_with_priority_range
    BasicJob.delay(queue: :default, priority: 1).perform
    BasicJob.delay(queue: :default, priority: 5).perform

    mapper = defined?(ActiveRecord) ? :active_record : :mongoid

    assert_equal 1, HireFire::Macro::Delayed::Job.queue(mapper: mapper, min_priority: 3)
    assert_equal 1, HireFire::Macro::Delayed::Job.queue(mapper: mapper, max_priority: 3)
    assert_equal 2, HireFire::Macro::Delayed::Job.queue(mapper: mapper, min_priority: 0, max_priority: 10)
  end

  def test_deprecated_queue_method_requires_a_mapper
    assert_raises ArgumentError do
      HireFire::Macro::Delayed::Job.queue(:default)
    end
  end

  def test_job_queue_working_idle_is_zero
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_working
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_working(:default)
  end

  def test_job_queue_working_counts_in_flight_and_filters_queues
    BasicJob.delay(queue: :default).perform.update(locked_at: Time.now, locked_by: "worker-1")
    BasicJob.delay(queue: :mailer).perform.update(locked_at: Time.now, locked_by: "worker-2")

    assert_equal 2, HireFire::Macro::Delayed::Job.job_queue_working
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_working(:default)
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_working(:mailer)
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_working(:critical)
    assert_equal 2, HireFire::Macro::Delayed::Job.job_queue_working(:default, :mailer)
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
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_size(:other)
  end

  def test_plan_execute_delayed_job_jqs_also_samples_wrk
    HireFire.configure { |c| c.logger = Logger.new(File::NULL) }
    buffer = HireFire.configuration.buffer
    buffer.flush

    BasicJob.delay(queue: :default).perform.update(locked_at: Time.now, locked_by: "worker-1")
    BasicJob.delay(queue: :default).perform

    HireFire::Plan.execute(
      "name" => "worker",
      "adapter" => "delayed_job",
      "strategy" => "jqs",
      "queues" => ["default"],
      "options" => {}
    )

    flushed = buffer.flush
    assert flushed["worker"], "plan must buffer under process name"
    assert flushed["worker"]["jqs"], "plan must sample jqs"
    assert flushed["worker"]["wrk"], "plan must sample wrk companion"

    jqs_value = flushed["worker"]["jqs"].values.last
    wrk_value = flushed["worker"]["wrk"].values.last
    assert_kind_of Numeric, jqs_value
    assert_kind_of Numeric, wrk_value
    assert_equal HireFire::Macro::Delayed::Job.job_queue_working(:default), wrk_value
    assert_equal HireFire::Macro::Delayed::Job.job_queue_size(:default), jqs_value
    assert_operator wrk_value, :>, 0
  end

  def test_plan_execute_delayed_job_jql_also_samples_wrk
    HireFire.configure { |c| c.logger = Logger.new(File::NULL) }
    buffer = HireFire.configuration.buffer
    buffer.flush

    BasicJob.delay(queue: :default).perform.update(locked_at: Time.now, locked_by: "worker-1")

    HireFire::Plan.execute(
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

    HireFire::Plan.execute(
      "name" => "worker",
      "adapter" => "delayed_job",
      "strategy" => "jqs",
      "queues" => [],
      "options" => {}
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
