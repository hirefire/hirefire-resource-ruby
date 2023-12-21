# frozen_string_literal: true

require "test_helper"

require_relative "../../env/rails_que_2/config/environment"

class HireFire::Macro::QueTest < Minitest::Test
  LATENCY_DELTA = 10

  def setup
    prepare_database
  end

  def test_missing_queues_raises_error
    assert_raises HireFire::Errors::MissingQueueError do
      HireFire::Macro::Que.job_queue_size
    end
  end

  def test_job_queue_size_without_jobs
    assert_equal 0, HireFire::Macro::Que.job_queue_size(:default)
  end

  def test_job_queue_size_with_jobs
    Que.enqueue(job_options: {job_class: "BasicJob", queue: "default"})
    Que.enqueue(job_options: {job_class: "BasicJob", queue: "mailer"})
    assert_equal 1, HireFire::Macro::Que.job_queue_size(:default)
    assert_equal 2, HireFire::Macro::Que.job_queue_size(:default, :mailer)
  end

  def test_job_queue_size_with_scheduled_jobs
    Que.enqueue(job_options: {job_class: "BasicJob", run_at: Time.now - 100})
    Que.enqueue(job_options: {job_class: "BasicJob", run_at: Time.now + 100})
    assert_equal 1, HireFire::Macro::Que.job_queue_size(:default)
  end

  def test_job_queue_size_with_prioritized_jobs
    Que.enqueue(job_options: {job_class: "BasicJob", priority: 300})
    Que.enqueue(job_options: {job_class: "BasicJob", priority: 500})
    Que.enqueue(job_options: {job_class: "BasicJob", priority: 700})
    assert_equal 3, HireFire::Macro::Que.job_queue_size(:default)
    assert_equal 1, HireFire::Macro::Que.job_queue_size(:default, priority: 300)
    assert_equal 1, HireFire::Macro::Que.job_queue_size(:default, priority: 500)
    assert_equal 1, HireFire::Macro::Que.job_queue_size(:default, priority: 700)
    assert_equal 2, HireFire::Macro::Que.job_queue_size(:default, priority: 300..500)
    assert_equal 2, HireFire::Macro::Que.job_queue_size(:default, priority: 500..700)
  end

  def test_job_queue_size_skip_finished_jobs
    job = Que.enqueue(job_options: {job_class: "BasicJob"})
    Que.execute("UPDATE que_jobs SET finished_at = NOW() WHERE id = #{job.que_attrs[:id]};")
    assert_equal 0, HireFire::Macro::Que.job_queue_size(:default)
  end

  def test_job_queue_size_skip_expired_jobs
    job = Que.enqueue(job_options: {job_class: "BasicJob"})
    Que.execute("UPDATE que_jobs SET expired_at = NOW() WHERE id = #{job.que_attrs[:id]};")
    assert_equal 0, HireFire::Macro::Que.job_queue_size(:default)
  end

  def test_job_queue_latency_without_jobs
    assert_equal 0, HireFire::Macro::Que.job_queue_latency(:default)
  end

  def test_job_queue_latency_with_jobs
    Que.enqueue(job_options: {job_class: "BasicJob", queue: "default", run_at: Time.now - 60})
    Que.enqueue(job_options: {job_class: "BasicJob", queue: "default"})
    Que.enqueue(job_options: {job_class: "BasicJob", queue: "mailer", run_at: Time.now - 120})
    assert_in_delta 60, HireFire::Macro::Que.job_queue_latency(:default), LATENCY_DELTA
  end

  def test_job_queue_latency_with_scheduled_jobs
    Que.enqueue(job_options: {job_class: "BasicJob", run_at: Time.now - 100})
    Que.enqueue(job_options: {job_class: "BasicJob", run_at: Time.now + 100})
    assert_equal 100, HireFire::Macro::Que.job_queue_latency(:default)
  end

  def test_job_queue_latency_with_prioritized_jobs
    Que.enqueue(job_options: {job_class: "BasicJob", priority: 300, run_at: Time.now - 300})
    Que.enqueue(job_options: {job_class: "BasicJob", priority: 500, run_at: Time.now - 600})
    Que.enqueue(job_options: {job_class: "BasicJob", priority: 700, run_at: Time.now - 900})
    assert_in_delta 300, HireFire::Macro::Que.job_queue_latency(:default, priority: 300), LATENCY_DELTA
    assert_in_delta 600, HireFire::Macro::Que.job_queue_latency(:default, priority: 500), LATENCY_DELTA
    assert_in_delta 900, HireFire::Macro::Que.job_queue_latency(:default, priority: 700), LATENCY_DELTA
    assert_in_delta 300, HireFire::Macro::Que.job_queue_latency(:default), LATENCY_DELTA
    assert_in_delta 300, HireFire::Macro::Que.job_queue_latency(:default, priority: 300..500), LATENCY_DELTA
    assert_in_delta 600, HireFire::Macro::Que.job_queue_latency(:default, priority: 500..700), LATENCY_DELTA
  end

  def test_job_queue_latency_skip_finished_jobs
    job = Que.enqueue(job_options: {job_class: "BasicJob", run_at: Time.now - 60})
    Que.execute("UPDATE que_jobs SET finished_at = NOW() WHERE id = #{job.que_attrs[:id]};")
    assert_equal 0, HireFire::Macro::Que.job_queue_latency(:default)
  end

  def test_job_queue_latency_skip_expired_jobs
    job = Que.enqueue(job_options: {job_class: "BasicJob", run_at: Time.now - 60})
    Que.execute("UPDATE que_jobs SET expired_at = NOW() WHERE id = #{job.que_attrs[:id]};")
    assert_equal 0, HireFire::Macro::Que.job_queue_latency(:default)
  end

  def test_deprecated_queue_method
    Que.enqueue(job_options: {job_class: "BasicJob", queue: "default"})
    assert_equal 1, HireFire::Macro::Que.queue(:default)
  end

  private

  def prepare_database
    db_config = Rails.configuration.database_configuration[Rails.env]

    ActiveRecord::Base.establish_connection(db_config)

    begin
      ActiveRecord::Base.connection
    rescue ActiveRecord::NoDatabaseError
      ActiveRecord::Tasks::DatabaseTasks.create(db_config)
      ActiveRecord::Base.establish_connection(db_config)
    end

    ActiveRecord::Migration.verbose = false
    ActiveRecord::MigrationContext.new(Rails.root.join("db/migrate").to_s).migrate

    Que.execute("DELETE FROM que_jobs")
  end
end
