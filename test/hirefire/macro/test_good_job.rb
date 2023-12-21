# frozen_string_literal: true

require "test_helper"
require "good_job/version"

if Gem::Version.new(::GoodJob::VERSION) >= Gem::Version.new("3.0.0")
  require_relative "../../env/rails_good_job_3/config/environment"
else
  require_relative "../../env/rails_good_job_2/config/environment"
end

class HireFire::Macro::GoodJobTest < Minitest::Test
  LATENCY_DELTA = 10

  def setup
    prepare_database
  end

  def test_missing_queues_raises_error
    assert_raises HireFire::Errors::MissingQueueError do
      HireFire::Macro::GoodJob.job_queue_size
    end
  end

  def test_job_queue_size_without_jobs
    assert_equal 0, HireFire::Macro::GoodJob.job_queue_size(:default)
  end

  def test_job_queue_size_with_jobs
    BasicJob.perform_later
    BasicJob.set(queue: :mailer).perform_later
    assert_equal 1, HireFire::Macro::GoodJob.job_queue_size(:default)
    assert_equal 2, HireFire::Macro::GoodJob.job_queue_size(:default, :mailer)
  end

  def test_job_queue_size_with_prioritized_jobs
    BasicJob.set(priority: 3).perform_later
    BasicJob.set(priority: 5).perform_later
    BasicJob.set(priority: 7).perform_later
    assert_equal 3, HireFire::Macro::GoodJob.job_queue_size(:default)
    assert_equal 1, HireFire::Macro::GoodJob.job_queue_size(:default, priority: 3)
    assert_equal 1, HireFire::Macro::GoodJob.job_queue_size(:default, priority: 5)
    assert_equal 1, HireFire::Macro::GoodJob.job_queue_size(:default, priority: 7)
    assert_equal 3, HireFire::Macro::GoodJob.job_queue_size(:default, priority: 3..7)
  end

  def test_job_queue_size_with_scheduled_jobs
    BasicJob.set(wait_until: 1.minute.ago).perform_later
    BasicJob.set(wait_until: 1.minute.from_now).perform_later
    assert_equal 1, HireFire::Macro::GoodJob.job_queue_size(:default)
  end

  def test_job_queue_size_with_finished_jobs
    job_id = BasicJob.perform_later.job_id
    GoodJob::Execution.where(active_job_id: job_id).update_all(finished_at: Time.now)
    assert_equal 0, HireFire::Macro::GoodJob.job_queue_size(:default)
  end

  def test_job_queue_latency_without_jobs
    assert_equal 0, HireFire::Macro::GoodJob.job_queue_latency(:default)
  end

  def test_job_queue_latency_with_jobs
    BasicJob.perform_later
    Timecop.freeze(1.minute.ago) { BasicJob.set(queue: :mailer).perform_later }
    assert_in_delta 0, HireFire::Macro::GoodJob.job_queue_latency(:default), LATENCY_DELTA
    assert_in_delta 60, HireFire::Macro::GoodJob.job_queue_latency(:default, :mailer), LATENCY_DELTA
  end

  def test_job_queue_latency_with_scheduled_job
    BasicJob.set(wait_until: 1.minute.from_now).perform_later
    BasicJob.set(queue: :mailer, wait_until: 1.minute.ago).perform_later
    assert_equal 0, HireFire::Macro::GoodJob.job_queue_latency(:default)
    assert_equal 60, HireFire::Macro::GoodJob.job_queue_latency(:mailer)
  end

  def test_job_queue_latency_with_prioritized_jobs
    BasicJob.set(priority: 3, wait_until: 5.minutes.ago).perform_later
    BasicJob.set(priority: 5, wait_until: 10.minutes.ago).perform_later
    BasicJob.set(priority: 7, wait_until: 15.minutes.ago).perform_later
    assert_in_delta 300, HireFire::Macro::GoodJob.job_queue_latency(:default, priority: 3), LATENCY_DELTA
    assert_in_delta 600, HireFire::Macro::GoodJob.job_queue_latency(:default, priority: 5), LATENCY_DELTA

    # GoodJob 4.0.0 changed the way it handles priorities.
    # As of version 4.0.0 it will prioritize jobs with a lower priority number.
    if Gem::Version.new(::GoodJob::VERSION) >= Gem::Version.new("4.0.0")
      assert_in_delta 300, HireFire::Macro::GoodJob.job_queue_latency(:default), LATENCY_DELTA
      assert_in_delta 300, HireFire::Macro::GoodJob.job_queue_latency(:default, priority: 3..5), LATENCY_DELTA
      assert_in_delta 600, HireFire::Macro::GoodJob.job_queue_latency(:default, priority: 5..7), LATENCY_DELTA
    else
      assert_in_delta 900, HireFire::Macro::GoodJob.job_queue_latency(:default), LATENCY_DELTA
      assert_in_delta 600, HireFire::Macro::GoodJob.job_queue_latency(:default, priority: 3..5), LATENCY_DELTA
      assert_in_delta 900, HireFire::Macro::GoodJob.job_queue_latency(:default, priority: 5..7), LATENCY_DELTA

      begin
        revert = Rails.application.config.good_job.smaller_number_is_higher_priority
        Rails.application.config.good_job.smaller_number_is_higher_priority = true
        assert_in_delta 300, HireFire::Macro::GoodJob.job_queue_latency(:default), LATENCY_DELTA
        assert_in_delta 300, HireFire::Macro::GoodJob.job_queue_latency(:default, priority: 3..5), LATENCY_DELTA
        assert_in_delta 600, HireFire::Macro::GoodJob.job_queue_latency(:default, priority: 5..7), LATENCY_DELTA
      ensure
        Rails.application.config.good_job.smaller_number_is_higher_priority = revert
      end
    end
  end

  def test_job_queue_latency_finished_jobs
    job_id = Timecop.freeze(1.minute.ago) { BasicJob.perform_later.job_id }
    GoodJob::Execution.where(active_job_id: job_id).update_all(finished_at: Time.now)
    assert_equal 0, HireFire::Macro::GoodJob.job_queue_latency(:default)
  end

  def test_deprecated_queue_method
    BasicJob.perform_later
    assert_equal 1, HireFire::Macro::GoodJob.queue(:default)
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

    GoodJob::Execution.delete_all
  end
end
