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
    if defined?(ActiveRecord)
      prepare_active_record_database
    end

    if defined?(Mongoid)
      prepare_mongoid_database
    end
  end

  def test_job_queue_latency_without_jobs
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_latency
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

  def test_deprecated_queue_method
    BasicJob.delay(queue: :default).perform

    if defined?(ActiveRecord)
      assert_equal 1, HireFire::Macro::Delayed::Job.queue(:default, mapper: :active_record)
    elsif defined?(Mongoid)
      assert_equal 1, HireFire::Macro::Delayed::Job.queue(:default, mapper: :mongoid)
    end
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
