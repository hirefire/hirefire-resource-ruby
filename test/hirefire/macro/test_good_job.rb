# frozen_string_literal: true

require "test_helper"
require "good_job/version"
require "hirefire/macro/helpers/good_job"

major_version = Gem::Version.new(::GoodJob::VERSION).segments[0]
require_relative "../../env/rails_good_job_#{major_version}/config/environment"

class HireFire::Macro::GoodJobTest < Minitest::Test
  include HireFire::Macro::Helpers::GoodJob

  LATENCY_DELTA = 2

  def setup
    prepare_database
  end

  def test_job_queue_latency_without_jobs
    assert_equal 0, HireFire::Macro::GoodJob.job_queue_latency
  end

  def test_job_queue_latency_with_jobs
    BasicJob.perform_later
    Timecop.freeze(1.minute.ago) { BasicJob.set(queue: :mailer).perform_later }
    assert_in_delta 60, HireFire::Macro::GoodJob.job_queue_latency, LATENCY_DELTA
    assert_in_delta 0, HireFire::Macro::GoodJob.job_queue_latency(:default), LATENCY_DELTA
    assert_in_delta 60, HireFire::Macro::GoodJob.job_queue_latency(:default, :mailer), LATENCY_DELTA
  end

  def test_job_queue_latency_with_scheduled_job
    BasicJob.set(wait_until: 1.minute.from_now).perform_later
    BasicJob.set(queue: :mailer, wait_until: 1.minute.ago).perform_later
    assert_in_delta 60, HireFire::Macro::GoodJob.job_queue_latency, LATENCY_DELTA
    assert_in_delta 0, HireFire::Macro::GoodJob.job_queue_latency(:default), LATENCY_DELTA
    assert_in_delta 60, HireFire::Macro::GoodJob.job_queue_latency(:mailer), LATENCY_DELTA
  end

  def test_job_queue_latency_with_unfinished_jobs
    job_id = Timecop.freeze(1.minute.ago) { BasicJob.perform_later.job_id }
    good_job_class.where(active_job_id: job_id).update_all(performed_at: 1.minute.ago)
    assert_equal 0, HireFire::Macro::GoodJob.job_queue_latency
  end

  def test_job_queue_latency_with_discarded_jobs
    skip "GoodJob #{::GoodJob::VERSION} does not support error events" unless error_event_supported?
    job_id = Timecop.freeze(1.minute.ago) { BasicJob.perform_later.job_id }
    good_job_class.where(active_job_id: job_id).update_all(
      performed_at: nil,
      scheduled_at: 1.minute.ago,
      finished_at: 1.minute.ago,
      error_event: discarded_enum
    )
    assert_equal 0, HireFire::Macro::GoodJob.job_queue_latency
  end

  def test_job_queue_latency_with_retried_jobs
    skip "GoodJob #{::GoodJob::VERSION} does not support error events" unless error_event_supported?
    job_id = Timecop.freeze(1.minute.ago) { BasicJob.perform_later.job_id }
    good_job_class.where(active_job_id: job_id).update_all(
      performed_at: nil,
      scheduled_at: 1.minute.ago,
      error_event: retried_enum
    )
    assert_in_delta 60, HireFire::Macro::GoodJob.job_queue_latency, LATENCY_DELTA
    good_job_class.where(active_job_id: job_id).update_all(performed_at: Time.now)
    assert_equal 0, HireFire::Macro::GoodJob.job_queue_latency
  end

  def test_job_queue_size_without_jobs
    assert_equal 0, HireFire::Macro::GoodJob.job_queue_size
  end

  def test_job_queue_size_with_jobs
    BasicJob.perform_later
    BasicJob.set(queue: :mailer).perform_later
    assert_equal 2, HireFire::Macro::GoodJob.job_queue_size
    assert_equal 1, HireFire::Macro::GoodJob.job_queue_size(:default)
    assert_equal 2, HireFire::Macro::GoodJob.job_queue_size(:default, :mailer)
  end

  def test_job_queue_size_with_scheduled_jobs
    BasicJob.set(wait_until: 1.minute.ago).perform_later
    BasicJob.set(wait_until: 1.minute.from_now).perform_later
    assert_equal 1, HireFire::Macro::GoodJob.job_queue_size
  end

  def test_job_queue_size_with_unfinished_jobs
    job_id = BasicJob.perform_later.job_id
    good_job_class.where(active_job_id: job_id).update_all(performed_at: 1.minute.ago)
    assert_equal 0, HireFire::Macro::GoodJob.job_queue_size
  end

  def test_job_queue_size_with_discarded_jobs
    skip "GoodJob #{::GoodJob::VERSION} does not support error events" unless error_event_supported?
    job_id = Timecop.freeze(1.minute.ago) { BasicJob.perform_later.job_id }
    good_job_class.where(active_job_id: job_id).update_all(
      performed_at: nil,
      scheduled_at: 1.minute.ago,
      finished_at: 1.minute.ago,
      error_event: discarded_enum
    )
    assert_equal 0, HireFire::Macro::GoodJob.job_queue_size
  end

  def test_job_queue_size_with_retried_jobs
    skip "GoodJob #{::GoodJob::VERSION} does not support error events" unless error_event_supported?
    job_id = Timecop.freeze(1.minute.ago) { BasicJob.perform_later.job_id }
    good_job_class.where(active_job_id: job_id).update_all(
      performed_at: nil,
      scheduled_at: 1.minute.ago,
      error_event: retried_enum
    )
    assert_equal 1, HireFire::Macro::GoodJob.job_queue_size
    good_job_class.where(active_job_id: job_id).update_all(performed_at: Time.now)
    assert_equal 0, HireFire::Macro::GoodJob.job_queue_size
  end

  def test_deprecated_queue_method
    BasicJob.perform_later
    assert_equal 1, HireFire::Macro::GoodJob.queue(:default)
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

    good_job_class.delete_all
  end
end
