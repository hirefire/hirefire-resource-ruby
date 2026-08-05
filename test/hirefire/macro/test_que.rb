# frozen_string_literal: true

require "test_helper"
require "que"
require "pg"

class HireFire::Macro::QueTest < Minitest::Test
  VERSION_QUE = Gem::Version.new(defined?(Que::Version) ? Que::Version : Que::VERSION)
  VERSION_2_0_0 = Gem::Version.new("2.0.0")
  LATENCY_DELTA = 2

  if VERSION_QUE < VERSION_2_0_0
    require_relative "../../env/rails_que_1/config/environment"
  else
    require_relative "../../env/rails_que_2/config/environment"
  end

  def setup
    prepare_database
  end

  def test_job_queue_latency_without_jobs
    assert_equal 0, HireFire::Macro::Que.job_queue_latency
  end

  def test_job_queue_latency_with_jobs
    enqueue(job_options: {job_class: "BasicJob", queue: "default", run_at: Time.now - 60})
    enqueue(job_options: {job_class: "BasicJob", queue: "default", run_at: Time.now - 1})
    enqueue(job_options: {job_class: "BasicJob", queue: "mailer", run_at: Time.now - 120})
    assert_in_delta 120, HireFire::Macro::Que.job_queue_latency, LATENCY_DELTA
    assert_in_delta 60, HireFire::Macro::Que.job_queue_latency(:default), LATENCY_DELTA
    assert_in_delta 120, HireFire::Macro::Que.job_queue_latency(:default, :mailer), LATENCY_DELTA
  end

  def test_job_queue_latency_with_scheduled_jobs
    enqueue(job_options: {job_class: "BasicJob", run_at: Time.now - 60})
    enqueue(job_options: {job_class: "BasicJob", run_at: Time.now + 90})
    assert_in_delta 60, HireFire::Macro::Que.job_queue_latency, LATENCY_DELTA
  end

  def test_job_queue_latency_skip_finished_jobs
    job = enqueue(job_options: {job_class: "BasicJob", run_at: Time.now - 60})
    Que.execute("UPDATE que_jobs SET finished_at = NOW() WHERE id = #{job.que_attrs[:id]};")
    assert_equal 0, HireFire::Macro::Que.job_queue_latency
  end

  def test_job_queue_latency_skip_expired_jobs
    job = enqueue(job_options: {job_class: "BasicJob", run_at: Time.now - 60})
    Que.execute("UPDATE que_jobs SET expired_at = NOW() WHERE id = #{job.que_attrs[:id]};")
    assert_equal 0, HireFire::Macro::Que.job_queue_latency
  end

  def test_job_queue_latency_excludes_advisory_locked_jobs
    job = enqueue(job_options: {job_class: "BasicJob", queue: "default", run_at: Time.now - 60})
    with_advisory_lock(job.que_attrs[:id]) do
      assert_equal 0, HireFire::Macro::Que.job_queue_latency
      assert_equal 0, HireFire::Macro::Que.job_queue_latency(:default)
    end
  end

  def test_job_queue_latency_ignores_locked_when_unlocked_due_exists
    locked = enqueue(job_options: {job_class: "BasicJob", queue: "default", run_at: Time.now - 180})
    enqueue(job_options: {job_class: "BasicJob", queue: "mailer", run_at: Time.now - 60})

    with_advisory_lock(locked.que_attrs[:id]) do
      assert_in_delta 60, HireFire::Macro::Que.job_queue_latency, LATENCY_DELTA
      assert_equal 0, HireFire::Macro::Que.job_queue_latency(:default)
      assert_in_delta 60, HireFire::Macro::Que.job_queue_latency(:mailer), LATENCY_DELTA
    end
  end

  def test_job_queue_size_without_jobs
    assert_equal 0, HireFire::Macro::Que.job_queue_size
  end

  def test_job_queue_size_with_jobs
    enqueue(job_options: {job_class: "BasicJob", queue: "default", run_at: Time.now - 1})
    enqueue(job_options: {job_class: "BasicJob", queue: "mailer", run_at: Time.now - 1})
    assert_equal 2, HireFire::Macro::Que.job_queue_size
    assert_equal 1, HireFire::Macro::Que.job_queue_size(:default)
    assert_equal 2, HireFire::Macro::Que.job_queue_size(:default, :mailer)
  end

  def test_job_queue_size_with_scheduled_jobs
    enqueue(job_options: {job_class: "BasicJob", run_at: Time.now - 100})
    enqueue(job_options: {job_class: "BasicJob", run_at: Time.now + 100})
    assert_equal 1, HireFire::Macro::Que.job_queue_size
  end

  def test_job_queue_size_with_special_character_queue_names
    enqueue(job_options: {job_class: "BasicJob", queue: "o'brien", run_at: Time.now - 1})
    enqueue(job_options: {job_class: "BasicJob", queue: "a,b", run_at: Time.now - 1})
    assert_equal 1, HireFire::Macro::Que.job_queue_size(:"o'brien")
    assert_equal 2, HireFire::Macro::Que.job_queue_size(:"o'brien", :"a,b")
  end

  def test_job_queue_latency_with_special_character_queue_names
    enqueue(job_options: {job_class: "BasicJob", queue: "o'brien", run_at: Time.now - 60})
    assert_in_delta 60, HireFire::Macro::Que.job_queue_latency(:"o'brien"), LATENCY_DELTA
  end

  def test_job_queue_size_skip_finished_jobs
    job = enqueue(job_options: {job_class: "BasicJob", run_at: Time.now - 1})
    Que.execute("UPDATE que_jobs SET finished_at = NOW() WHERE id = #{job.que_attrs[:id]};")
    assert_equal 0, HireFire::Macro::Que.job_queue_size
  end

  def test_job_queue_size_skip_expired_jobs
    job = enqueue(job_options: {job_class: "BasicJob", run_at: Time.now - 1})
    Que.execute("UPDATE que_jobs SET expired_at = NOW() WHERE id = #{job.que_attrs[:id]};")
    assert_equal 0, HireFire::Macro::Que.job_queue_size
  end

  def test_job_queue_size_excludes_advisory_locked_jobs
    job = enqueue(job_options: {job_class: "BasicJob", queue: "default", run_at: Time.now - 1})
    with_advisory_lock(job.que_attrs[:id]) do
      assert_equal 0, HireFire::Macro::Que.job_queue_size
      assert_equal 0, HireFire::Macro::Que.job_queue_size(:default)
    end
  end

  def test_job_queue_size_counts_due_unlocked_only_with_locked_and_future_present
    enqueue(job_options: {job_class: "BasicJob", queue: "default", run_at: Time.now - 1})
    enqueue(job_options: {job_class: "BasicJob", queue: "mailer", run_at: Time.now - 1})
    enqueue(job_options: {job_class: "BasicJob", queue: "default", run_at: Time.now + 100})
    locked = enqueue(job_options: {job_class: "BasicJob", queue: "other", run_at: Time.now - 1})

    with_advisory_lock(locked.que_attrs[:id]) do
      assert_equal 2, HireFire::Macro::Que.job_queue_size
      assert_equal 1, HireFire::Macro::Que.job_queue_size(:default)
      assert_equal 1, HireFire::Macro::Que.job_queue_size(:mailer)
      assert_equal 0, HireFire::Macro::Que.job_queue_size(:other)
      assert_equal 2, HireFire::Macro::Que.job_queue_size(:default, :mailer)
    end
  end

  def test_job_queue_size_counts_due_jobs_with_error_count
    job = enqueue(job_options: {job_class: "BasicJob", run_at: Time.now - 1})
    Que.execute("UPDATE que_jobs SET error_count = 3 WHERE id = #{job.que_attrs[:id]};")

    # Do not copy Que AR `ready` (drops error_count > 0). Due retries still wait.
    assert_equal 1, HireFire::Macro::Que.job_queue_size
  end

  def test_job_queue_latency_includes_due_jobs_with_error_count
    job = enqueue(job_options: {job_class: "BasicJob", run_at: Time.now - 60})
    Que.execute("UPDATE que_jobs SET error_count = 3 WHERE id = #{job.que_attrs[:id]};")

    # Same waiting set as size: do not drop error_count > 0 (Que AR `ready` would).
    assert_in_delta 60, HireFire::Macro::Que.job_queue_latency, LATENCY_DELTA
  end

  def test_v0_size_path_counts_due_jobs_without_finished_filter
    HireFire::Macro::Que.stubs(:version).returns(Gem::Version.new("0.14.3"))
    # Test DB is Que 1+/2 schema (`id`, not `job_id`). Pin lock column so v0 SQL runs.
    HireFire::Macro::Que.stubs(:advisory_lock_id_column).returns("id")

    enqueue(job_options: {job_class: "BasicJob", queue: "default", run_at: Time.now - 1})
    enqueue(job_options: {job_class: "BasicJob", queue: "mailer", run_at: Time.now - 1})
    enqueue(job_options: {job_class: "BasicJob", run_at: Time.now + 100})

    assert_equal 2, HireFire::Macro::Que.job_queue_size
    assert_equal 1, HireFire::Macro::Que.job_queue_size(:default)
  end

  def test_v0_size_path_includes_finished_jobs
    HireFire::Macro::Que.stubs(:version).returns(Gem::Version.new("0.14.3"))
    HireFire::Macro::Que.stubs(:advisory_lock_id_column).returns("id")

    job = enqueue(job_options: {job_class: "BasicJob", run_at: Time.now - 1})
    Que.execute("UPDATE que_jobs SET finished_at = NOW() WHERE id = #{job.que_attrs[:id]};")

    # v0 SQL has no finished_at/expired_at predicates (those columns are v1+).
    assert_equal 1, HireFire::Macro::Que.job_queue_size
  end

  def test_v0_latency_path_reports_oldest_due_job
    HireFire::Macro::Que.stubs(:version).returns(Gem::Version.new("0.14.3"))
    HireFire::Macro::Que.stubs(:advisory_lock_id_column).returns("id")

    enqueue(job_options: {job_class: "BasicJob", run_at: Time.now - 60})
    enqueue(job_options: {job_class: "BasicJob", run_at: Time.now - 10})

    assert_in_delta 60, HireFire::Macro::Que.job_queue_latency, LATENCY_DELTA
  end

  def test_v0_size_path_excludes_advisory_locked_jobs
    HireFire::Macro::Que.stubs(:version).returns(Gem::Version.new("0.14.3"))
    HireFire::Macro::Que.stubs(:advisory_lock_id_column).returns("id")

    job = enqueue(job_options: {job_class: "BasicJob", run_at: Time.now - 1})
    with_advisory_lock(job.que_attrs[:id]) do
      assert_equal 0, HireFire::Macro::Que.job_queue_size
    end
  end

  def test_v0_latency_path_excludes_advisory_locked_jobs
    HireFire::Macro::Que.stubs(:version).returns(Gem::Version.new("0.14.3"))
    HireFire::Macro::Que.stubs(:advisory_lock_id_column).returns("id")

    job = enqueue(job_options: {job_class: "BasicJob", run_at: Time.now - 60})
    with_advisory_lock(job.que_attrs[:id]) do
      assert_equal 0, HireFire::Macro::Que.job_queue_latency
    end
  end

  def test_deprecated_queue_method
    enqueue(job_options: {job_class: "BasicJob", queue: "default", run_at: Time.now - 1})
    assert_equal 1, HireFire::Macro::Que.queue(:default)
  end

  def test_deprecated_queue_method_without_queues_counts_all
    enqueue(job_options: {job_class: "BasicJob", queue: "default", run_at: Time.now - 1})
    enqueue(job_options: {job_class: "BasicJob", queue: "mailer", run_at: Time.now - 1})
    assert_equal 2, HireFire::Macro::Que.queue
  end

  def test_deprecated_queue_method_with_special_character_queue_names
    enqueue(job_options: {job_class: "BasicJob", queue: "o'brien", run_at: Time.now - 1})
    assert_equal 1, HireFire::Macro::Que.queue(:"o'brien")
  end

  def test_deprecated_queue_method_excludes_advisory_locked_and_future
    enqueue(job_options: {job_class: "BasicJob", queue: "default", run_at: Time.now - 1})
    enqueue(job_options: {job_class: "BasicJob", queue: "default", run_at: Time.now + 100})
    locked = enqueue(job_options: {job_class: "BasicJob", queue: "default", run_at: Time.now - 1})

    with_advisory_lock(locked.que_attrs[:id]) do
      assert_equal 1, HireFire::Macro::Que.queue(:default)
    end
  end

  def test_job_queue_working_idle_is_zero
    assert_equal 0, HireFire::Macro::Que.job_queue_working
    assert_equal 0, HireFire::Macro::Que.job_queue_working(:default)
  end

  def test_job_queue_working_counts_in_flight_and_filters_queues
    default = enqueue(job_options: {job_class: "BasicJob", queue: "default", run_at: Time.now - 1})
    mailer = enqueue(job_options: {job_class: "BasicJob", queue: "mailer", run_at: Time.now - 1})
    enqueue(job_options: {job_class: "BasicJob", queue: "critical", run_at: Time.now - 1})

    with_advisory_locks(default.que_attrs[:id], mailer.que_attrs[:id]) do
      assert_equal 2, HireFire::Macro::Que.job_queue_working
      assert_equal 1, HireFire::Macro::Que.job_queue_working(:default)
      assert_equal 1, HireFire::Macro::Que.job_queue_working(:mailer)
      assert_equal 0, HireFire::Macro::Que.job_queue_working(:critical)
      assert_equal 2, HireFire::Macro::Que.job_queue_working(:default, :mailer)
      assert_equal 1, HireFire::Macro::Que.job_queue_size(:critical)
      assert_equal 0, HireFire::Macro::Que.job_queue_size(:default)
    end
  end

  def test_job_queue_working_excludes_finished_and_expired
    finished = enqueue(job_options: {job_class: "BasicJob", queue: "default", run_at: Time.now - 1})
    expired = enqueue(job_options: {job_class: "BasicJob", queue: "mailer", run_at: Time.now - 1})
    locked = enqueue(job_options: {job_class: "BasicJob", queue: "other", run_at: Time.now - 1})
    Que.execute("UPDATE que_jobs SET finished_at = NOW() WHERE id = #{finished.que_attrs[:id]};")
    Que.execute("UPDATE que_jobs SET expired_at = NOW() WHERE id = #{expired.que_attrs[:id]};")

    with_advisory_locks(finished.que_attrs[:id], expired.que_attrs[:id], locked.que_attrs[:id]) do
      assert_equal 1, HireFire::Macro::Que.job_queue_working
      assert_equal 0, HireFire::Macro::Que.job_queue_working(:default)
      assert_equal 0, HireFire::Macro::Que.job_queue_working(:mailer)
      assert_equal 1, HireFire::Macro::Que.job_queue_working(:other)
    end
  end

  def test_plan_execute_que_jqs_also_samples_wrk
    HireFire.configure { |c| c.logger = Logger.new(File::NULL) }
    buffer = HireFire.configuration.buffer
    buffer.flush

    locked = enqueue(job_options: {job_class: "BasicJob", queue: "default", run_at: Time.now - 1})
    enqueue(job_options: {job_class: "BasicJob", queue: "default", run_at: Time.now - 1})

    with_advisory_lock(locked.que_attrs[:id]) do
      HireFire::Plan.execute(
        "name" => "worker",
        "adapter" => "que",
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
      assert_equal HireFire::Macro::Que.job_queue_working(:default), wrk_value
      assert_equal HireFire::Macro::Que.job_queue_size(:default), jqs_value
      assert_operator wrk_value, :>, 0
    end
  end

  def test_plan_execute_que_jql_also_samples_wrk
    HireFire.configure { |c| c.logger = Logger.new(File::NULL) }
    buffer = HireFire.configuration.buffer
    buffer.flush

    locked = enqueue(job_options: {job_class: "BasicJob", queue: "default", run_at: Time.now - 1})

    with_advisory_lock(locked.que_attrs[:id]) do
      HireFire::Plan.execute(
        "name" => "worker",
        "adapter" => "que",
        "strategy" => "jql",
        "queues" => ["default"],
        "options" => {}
      )

      flushed = buffer.flush
      assert flushed.dig("worker", "jql")
      assert_equal 1, flushed.dig("worker", "wrk")&.values&.last
    end
  end

  def test_plan_execute_que_empty_queues_samples_all_wrk
    HireFire.configure { |c| c.logger = Logger.new(File::NULL) }
    buffer = HireFire.configuration.buffer
    buffer.flush

    default = enqueue(job_options: {job_class: "BasicJob", queue: "default", run_at: Time.now - 1})
    mailer = enqueue(job_options: {job_class: "BasicJob", queue: "mailer", run_at: Time.now - 1})

    with_advisory_locks(default.que_attrs[:id], mailer.que_attrs[:id]) do
      HireFire::Plan.execute(
        "name" => "worker",
        "adapter" => "que",
        "strategy" => "jqs",
        "queues" => [],
        "options" => {}
      )

      flushed = buffer.flush
      assert_equal 2, flushed.dig("worker", "wrk")&.values&.last
      assert_equal HireFire::Macro::Que.job_queue_working, flushed.dig("worker", "wrk")&.values&.last
    end
  end

  private

  def enqueue(*args, job_options: {}, **options)
    options = options.merge(job_options: job_options)
    Que.enqueue(*args, **options)
  end

  # Hold a Que-style session advisory lock on a dedicated connection so the macro's
  # `pg_locks` anti-join sees working jobs. Residual lock count proves the lock is
  # present so size/latency zeros are not false-green from a failed lock acquire.
  def with_advisory_lock(job_id, &block)
    with_advisory_locks(job_id, &block)
  end

  def with_advisory_locks(*job_ids)
    conn = open_pg_connection
    job_ids.each do |job_id|
      locked = conn.exec_params("SELECT pg_try_advisory_lock($1)", [job_id]).getvalue(0, 0)
      refute_equal "f", locked, "expected pg_try_advisory_lock(#{job_id}) to succeed"

      lock_count = advisory_lock_count(job_id)
      refute_equal 0, lock_count, "expected pg_locks to show advisory lock for job #{job_id}"
    end

    yield
  ensure
    if conn
      begin
        conn.exec("SELECT pg_advisory_unlock_all()")
      ensure
        conn.close
      end
    end
  end

  def advisory_lock_count(job_id)
    result = Que.execute(<<~SQL, [job_id]).first
      SELECT COUNT(*) AS n
      FROM pg_locks
      WHERE locktype = 'advisory'
        AND (classid::bigint << 32) + objid::bigint = $1
    SQL
    (result[:n] || result["n"]).to_i
  end

  def open_pg_connection
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    PG.connect(
      host: config[:host],
      port: config[:port],
      dbname: config[:database],
      user: config[:username],
      password: config[:password]
    )
  end

  def prepare_database
    db_config = Rails.configuration.database_configuration[Rails.env]

    begin
      ActiveRecord::Base.establish_connection(db_config)
      Que.connection = ::ActiveRecord
      ActiveRecord::Migration.verbose = false
      ActiveRecord::MigrationContext.new(Rails.root.join("db/migrate").to_s).migrate
    rescue ActiveRecord::NoDatabaseError
      ActiveRecord::Tasks::DatabaseTasks.create(db_config)
      retry
    end

    Que.execute("DELETE FROM que_jobs")
  end
end
