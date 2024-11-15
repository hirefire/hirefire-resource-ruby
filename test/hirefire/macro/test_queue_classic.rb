# frozen_string_literal: true

require "test_helper"

require_relative "../../env/rails_queue_classic_4/config/environment"

class HireFire::Macro::QCTest < Minitest::Test
  LATENCY_DELTA = 2

  def setup
    prepare_database
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

  def test_job_queue_size_without_jobs
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

  def test_deprecated_queue_method
    QC::Queue.new("default").enqueue_at(1.minute.from_now.to_i, "BasicJob.perform")
    assert_equal 1, HireFire::Macro::QC.queue
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
