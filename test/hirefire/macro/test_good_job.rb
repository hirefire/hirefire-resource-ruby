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

  def test_job_queue_latency_prefers_oldest_by_coalesced_timestamp
    # An immediate job (scheduled_at NULL) created 10 minutes ago is the true
    # oldest, but a newer scheduled job has a non-NULL scheduled_at. Ordering by
    # scheduled_at alone sorts the NULL row last and under-reports latency.
    old_id = BasicJob.perform_later.job_id
    good_job_class.where(active_job_id: old_id).update_all(scheduled_at: nil, created_at: 10.minutes.ago)

    new_id = BasicJob.perform_later.job_id
    good_job_class.where(active_job_id: new_id).update_all(scheduled_at: 1.minute.ago, created_at: 1.minute.ago)

    assert_in_delta 600, HireFire::Macro::GoodJob.job_queue_latency, LATENCY_DELTA
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

  def test_error_event_support_follows_schema_not_version
    # The error_event column only arrived in GoodJob 3.16. Support must track the
    # live schema, not the gem version: an app on 3.0-3.15, or one that upgraded
    # the gem without running the migration, has no such column even though its
    # version is >= 3.0. A version-based gate would generate SQL referencing a
    # missing column and raise.
    real_columns = good_job_class.column_names
    good_job_class.stubs(:column_names).returns(real_columns - ["error_event"])
    refute error_event_supported?

    good_job_class.unstub(:column_names)
    assert_equal real_columns.include?("error_event"), error_event_supported?
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
