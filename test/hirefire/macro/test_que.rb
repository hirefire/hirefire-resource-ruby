# frozen_string_literal: true

require "test_helper"

require_relative "../../env/rails_que_2/config/environment"

class HireFire::Macro::QueTest < Minitest::Test
  LATENCY_DELTA = 2

  def setup
    prepare_database
  end

  def test_job_queue_latency_without_jobs
    assert_equal 0, HireFire::Macro::Que.job_queue_latency
  end

  def test_job_queue_latency_with_jobs
    Que.enqueue(job_options: {job_class: "BasicJob", queue: "default", run_at: Time.now - 60})
    Que.enqueue(job_options: {job_class: "BasicJob", queue: "default"})
    Que.enqueue(job_options: {job_class: "BasicJob", queue: "mailer", run_at: Time.now - 120})
    assert_in_delta 120, HireFire::Macro::Que.job_queue_latency, LATENCY_DELTA
    assert_in_delta 60, HireFire::Macro::Que.job_queue_latency(:default), LATENCY_DELTA
    assert_in_delta 120, HireFire::Macro::Que.job_queue_latency(:default, :mailer), LATENCY_DELTA
  end

  def test_job_queue_latency_with_scheduled_jobs
    Que.enqueue(job_options: {job_class: "BasicJob", run_at: Time.now - 60})
    Que.enqueue(job_options: {job_class: "BasicJob", run_at: Time.now + 90})
    assert_in_delta 60, HireFire::Macro::Que.job_queue_latency, LATENCY_DELTA
  end

  def test_job_queue_latency_skip_finished_jobs
    job = Que.enqueue(job_options: {job_class: "BasicJob", run_at: Time.now - 60})
    Que.execute("UPDATE que_jobs SET finished_at = NOW() WHERE id = #{job.que_attrs[:id]};")
    assert_equal 0, HireFire::Macro::Que.job_queue_latency
  end

  def test_job_queue_latency_skip_expired_jobs
    job = Que.enqueue(job_options: {job_class: "BasicJob", run_at: Time.now - 60})
    Que.execute("UPDATE que_jobs SET expired_at = NOW() WHERE id = #{job.que_attrs[:id]};")
    assert_equal 0, HireFire::Macro::Que.job_queue_latency
  end

  def test_job_queue_size_without_jobs
    assert_equal 0, HireFire::Macro::Que.job_queue_size
  end

  def test_job_queue_size_with_jobs
    Que.enqueue(job_options: {job_class: "BasicJob", queue: "default"})
    Que.enqueue(job_options: {job_class: "BasicJob", queue: "mailer"})
    assert_equal 2, HireFire::Macro::Que.job_queue_size
    assert_equal 1, HireFire::Macro::Que.job_queue_size(:default)
    assert_equal 2, HireFire::Macro::Que.job_queue_size(:default, :mailer)
  end

  def test_job_queue_size_with_scheduled_jobs
    Que.enqueue(job_options: {job_class: "BasicJob", run_at: Time.now - 100})
    Que.enqueue(job_options: {job_class: "BasicJob", run_at: Time.now + 100})
    assert_equal 1, HireFire::Macro::Que.job_queue_size
  end

  def test_job_queue_size_skip_finished_jobs
    job = Que.enqueue(job_options: {job_class: "BasicJob"})
    Que.execute("UPDATE que_jobs SET finished_at = NOW() WHERE id = #{job.que_attrs[:id]};")
    assert_equal 0, HireFire::Macro::Que.job_queue_size
  end

  def test_job_queue_size_skip_expired_jobs
    job = Que.enqueue(job_options: {job_class: "BasicJob"})
    Que.execute("UPDATE que_jobs SET expired_at = NOW() WHERE id = #{job.que_attrs[:id]};")
    assert_equal 0, HireFire::Macro::Que.job_queue_size
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
