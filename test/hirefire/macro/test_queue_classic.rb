# frozen_string_literal: true

require "test_helper"

require_relative "../../env/rails_queue_classic_4/config/environment"

class HireFire::Macro::QCTest < Minitest::Test
  LATENCY_DELTA = 2

  def setup
    super
    prepare_database
  end

  def test_library_loaded_is_true_when_queue_classic_gem_is_loaded
    assert HireFire::Plan.library_loaded?("queue_classic")
    assert HireFire::Plan.executable?("queue_classic")
    assert HireFire::Plan.any_allowlisted_job_queue_library_loaded?
  end

  def test_job_queue_latency_without_jobs
    assert_equal 0, HireFire::Macro::QC.job_queue_latency
  end

  def test_job_queue_latency_with_jobs
    QC::Queue.new("default").enqueue_at(1.minute.ago.to_i, "BasicJob.perform")
    QC::Queue.new("default").enqueue("BasicJob.perform")
    QC::Queue.new("mailer").enqueue_at(2.minutes.ago.to_i, "BasicJob.perform")
    assert_in_delta 120, HireFire::Macro::QC.job_queue_latency, LATENCY_DELTA
    assert_in_delta 60, HireFire::Macro::QC.job_queue_latency(:default), LATENCY_DELTA
    assert_in_delta 120, HireFire::Macro::QC.job_queue_latency(:default, :mailer), LATENCY_DELTA
  end

  def test_job_queue_latency_with_scheduled_job
    QC::Queue.new("default").enqueue_at(1.minute.from_now.to_i, "BasicJob.perform")
    QC::Queue.new("mailer").enqueue_at(1.minute.ago.to_i, "BasicJob.perform")
    assert_in_delta 60, HireFire::Macro::QC.job_queue_latency, LATENCY_DELTA
    assert_in_delta 0, HireFire::Macro::QC.job_queue_latency(:default), LATENCY_DELTA
    assert_in_delta 60, HireFire::Macro::QC.job_queue_latency(:mailer), LATENCY_DELTA
  end

  def test_job_queue_latency_excludes_locked_jobs
    queue = QC::Queue.new("default")
    queue.enqueue_at(1.minute.ago.to_i, "BasicJob.perform")
    locked = queue.lock
    refute_nil locked
    assert_equal 1, queue.count_ready

    assert_equal 0, HireFire::Macro::QC.job_queue_latency
    assert_equal 0, HireFire::Macro::QC.job_queue_latency(:default)
  end

  def test_job_queue_latency_ignores_locked_when_unlocked_due_exists
    default = QC::Queue.new("default")
    default.enqueue_at(3.minutes.ago.to_i, "BasicJob.perform")
    locked = default.lock
    refute_nil locked
    assert_equal 1, default.count_ready
    QC::Queue.new("mailer").enqueue_at(1.minute.ago.to_i, "BasicJob.perform")

    assert_in_delta 60, HireFire::Macro::QC.job_queue_latency, LATENCY_DELTA
    assert_equal 0, HireFire::Macro::QC.job_queue_latency(:default)
    assert_in_delta 60, HireFire::Macro::QC.job_queue_latency(:mailer), LATENCY_DELTA
  end

  def test_job_queue_size_without_jobs
    assert_equal 0, HireFire::Macro::QC.job_queue_size
    assert_equal 0, HireFire::Macro::QC.job_queue_size(:default)
  end

  def test_job_queue_size_with_jobs
    QC::Queue.new("default").enqueue("BasicJob.perform")
    QC::Queue.new("mailer").enqueue("BasicJob.perform")
    assert_equal 2, HireFire::Macro::QC.job_queue_size
    assert_equal 1, HireFire::Macro::QC.job_queue_size(:default)
    assert_equal 2, HireFire::Macro::QC.job_queue_size(:default, :mailer)
  end

  def test_job_queue_size_with_scheduled_jobs
    QC::Queue.new("default").enqueue_at(1.minute.ago, "BasicJob.perform")
    QC::Queue.new("default").enqueue_at(1.minute.from_now, "BasicJob.perform")
    assert_equal 1, HireFire::Macro::QC.job_queue_size
  end

  def test_job_queue_size_excludes_locked_jobs
    queue = QC::Queue.new("default")
    queue.enqueue("BasicJob.perform")
    locked = queue.lock
    refute_nil locked
    assert_equal 1, queue.count_ready

    assert_equal 0, HireFire::Macro::QC.job_queue_size
    assert_equal 0, HireFire::Macro::QC.job_queue_size(:default)
  end

  def test_job_queue_size_counts_due_unlocked_only_with_locked_and_future_present
    QC::Queue.new("default").enqueue("BasicJob.perform")
    QC::Queue.new("mailer").enqueue("BasicJob.perform")
    QC::Queue.new("default").enqueue_at(1.minute.from_now.to_i, "BasicJob.perform")
    other = QC::Queue.new("other")
    other.enqueue("BasicJob.perform")
    locked = other.lock
    refute_nil locked
    assert_equal 1, other.count_ready

    assert_equal 2, HireFire::Macro::QC.job_queue_size
    assert_equal 1, HireFire::Macro::QC.job_queue_size(:default)
    assert_equal 1, HireFire::Macro::QC.job_queue_size(:mailer)
    assert_equal 0, HireFire::Macro::QC.job_queue_size(:other)
    assert_equal 2, HireFire::Macro::QC.job_queue_size(:default, :mailer)
  end

  def test_job_queue_size_with_comma_in_queue_name
    QC::Queue.new("a,b").enqueue("BasicJob.perform")
    assert_equal 1, HireFire::Macro::QC.job_queue_size(:"a,b")
  end

  def test_job_queue_latency_with_comma_in_queue_name
    QC::Queue.new("a,b").enqueue_at(1.minute.ago.to_i, "BasicJob.perform")
    assert_in_delta 60, HireFire::Macro::QC.job_queue_latency(:"a,b"), LATENCY_DELTA
  end

  def test_deprecated_queue_method
    QC::Queue.new("default").enqueue("BasicJob.perform")
    assert_equal 1, HireFire::Macro::QC.queue
  end

  def test_deprecated_queue_method_excludes_locked_and_future
    queue = QC::Queue.new("default")
    queue.enqueue("BasicJob.perform")
    queue.enqueue_at(1.minute.from_now.to_i, "BasicJob.perform")
    queue.enqueue("BasicJob.perform")
    locked = queue.lock
    refute_nil locked
    assert_equal 2, queue.count_ready

    assert_equal 1, HireFire::Macro::QC.queue
  end

  def test_job_queue_working_idle_is_zero
    assert_equal 0, HireFire::Macro::QC.job_queue_working
    assert_equal 0, HireFire::Macro::QC.job_queue_working(:default)
  end

  def test_job_queue_working_counts_in_flight_and_filters_queues
    default = QC::Queue.new("default")
    mailer = QC::Queue.new("mailer")
    default.enqueue("BasicJob.perform")
    mailer.enqueue("BasicJob.perform")
    refute_nil default.lock
    refute_nil mailer.lock

    assert_equal 2, HireFire::Macro::QC.job_queue_working
    assert_equal 1, HireFire::Macro::QC.job_queue_working(:default)
    assert_equal 1, HireFire::Macro::QC.job_queue_working(:mailer)
    assert_equal 0, HireFire::Macro::QC.job_queue_working(:critical)
    assert_equal 2, HireFire::Macro::QC.job_queue_working(:default, :mailer)
  end

  def test_job_queue_working_excludes_unlocked
    QC::Queue.new("default").enqueue("BasicJob.perform")
    other = QC::Queue.new("other")
    other.enqueue("BasicJob.perform")
    refute_nil other.lock

    assert_equal 1, HireFire::Macro::QC.job_queue_working
    assert_equal 0, HireFire::Macro::QC.job_queue_working(:default)
    assert_equal 1, HireFire::Macro::QC.job_queue_working(:other)
    assert_equal 1, HireFire::Macro::QC.job_queue_size(:default)
    assert_equal 0, HireFire::Macro::QC.job_queue_size(:other)
  end

  def test_plan_execute_queue_classic_jqs_also_samples_wrk
    HireFire.configure { |c| c.logger = Logger.new(File::NULL) }
    buffer = HireFire.configuration.buffer
    buffer.flush

    queue = QC::Queue.new("default")
    queue.enqueue("BasicJob.perform")
    refute_nil queue.lock
    queue.enqueue("BasicJob.perform")

    HireFire::Plan.execute(
      "name" => "worker",
      "adapter" => "queue_classic",
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
    assert_equal HireFire::Macro::QC.job_queue_working(:default), wrk_value
    assert_equal HireFire::Macro::QC.job_queue_size(:default), jqs_value
    assert_operator wrk_value, :>, 0
  end

  def test_plan_execute_queue_classic_jql_also_samples_wrk
    HireFire.configure { |c| c.logger = Logger.new(File::NULL) }
    buffer = HireFire.configuration.buffer
    buffer.flush

    queue = QC::Queue.new("default")
    queue.enqueue("BasicJob.perform")
    refute_nil queue.lock

    HireFire::Plan.execute(
      "name" => "worker",
      "adapter" => "queue_classic",
      "strategy" => "jql",
      "queues" => ["default"],
      "options" => {}
    )

    flushed = buffer.flush
    assert flushed.dig("worker", "jql")
    assert_equal 1, flushed.dig("worker", "wrk")&.values&.last
  end

  def test_plan_execute_queue_classic_empty_queues_samples_all_wrk
    HireFire.configure { |c| c.logger = Logger.new(File::NULL) }
    buffer = HireFire.configuration.buffer
    buffer.flush

    default = QC::Queue.new("default")
    mailer = QC::Queue.new("mailer")
    default.enqueue("BasicJob.perform")
    mailer.enqueue("BasicJob.perform")
    refute_nil default.lock
    refute_nil mailer.lock

    HireFire::Plan.execute(
      "name" => "worker",
      "adapter" => "queue_classic",
      "strategy" => "jqs",
      "queues" => [],
      "options" => {}
    )

    flushed = buffer.flush
    assert_equal 2, flushed.dig("worker", "wrk")&.values&.last
    assert_equal HireFire::Macro::QC.job_queue_working, flushed.dig("worker", "wrk")&.values&.last
  end

  def test_job_queue_size_releases_the_active_record_connection
    pool = ActiveRecord::Base.connection_pool
    started = Queue.new
    release = Queue.new
    holder = Thread.new do
      HireFire::Macro::QC.job_queue_size
      started << true
      release.pop
    end
    started.pop
    assert_operator pool.stat[:busy], :<=, 1
  ensure
    release << true
    holder&.join
  end

  private

  def prepare_database
    db_config = Rails.configuration.database_configuration[Rails.env]

    begin
      ActiveRecord::Base.establish_connection(db_config)
      ActiveRecord::Migration.verbose = false
      ActiveRecord::MigrationContext.new(Rails.root.join("db/migrate").to_s).migrate
    rescue ActiveRecord::NoDatabaseError
      ActiveRecord::Tasks::DatabaseTasks.create(db_config)
      retry
    end

    QC::Queue.new("default").conn_adapter.execute("DELETE FROM #{::QC.table_name}")
  end
end
