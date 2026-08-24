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
    super
    prepare_database
  end

  def test_library_loaded_is_true_when_good_job_gem_is_loaded
    assert HireFire::Plan.library_loaded?("good_job")
    assert HireFire::Plan.executable?("good_job")
    assert HireFire::Plan.any_allowlisted_job_queue_library_loaded?
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
    old_id = BasicJob.perform_later.job_id
    good_job_class.where(active_job_id: old_id).update_all(scheduled_at: nil, created_at: 10.minutes.ago)

    new_id = BasicJob.perform_later.job_id
    good_job_class.where(active_job_id: new_id).update_all(scheduled_at: 1.minute.ago, created_at: 1.minute.ago)

    assert_in_delta 600, HireFire::Macro::GoodJob.job_queue_latency, LATENCY_DELTA
  end

  def test_job_queue_latency_excludes_running_jobs
    job_id = Timecop.freeze(1.minute.ago) { BasicJob.perform_later.job_id }
    mark_running(job_id, at: 1.minute.ago)
    assert_equal 0, HireFire::Macro::GoodJob.job_queue_latency
  end

  def test_job_queue_latency_excludes_finished_before_perform_without_discard_event
    job_id = Timecop.freeze(2.minutes.ago) { BasicJob.perform_later.job_id }
    mark_finished_before_perform(job_id, finished_at: 1.minute.ago, scheduled_at: 2.minutes.ago)
    assert_equal 0, HireFire::Macro::GoodJob.job_queue_latency
  end

  def test_job_queue_latency_with_discarded_jobs
    skip "GoodJob #{::GoodJob::VERSION} does not support error events" unless error_event_supported?
    job_id = Timecop.freeze(1.minute.ago) { BasicJob.perform_later.job_id }
    mark_discarded(job_id, at: 1.minute.ago)
    assert_equal 0, HireFire::Macro::GoodJob.job_queue_latency
  end

  def test_job_queue_latency_with_retried_jobs
    skip "GoodJob #{::GoodJob::VERSION} does not support error events" unless error_event_supported?
    job_id = Timecop.freeze(1.minute.ago) { BasicJob.perform_later.job_id }
    good_job_class.where(active_job_id: job_id).update_all(
      performed_at: nil,
      finished_at: nil,
      scheduled_at: 1.minute.ago,
      error_event: retried_enum
    )
    assert_in_delta 60, HireFire::Macro::GoodJob.job_queue_latency, LATENCY_DELTA
    mark_running(job_id, at: Time.now)
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

  def test_job_queue_size_includes_null_scheduled_at
    job_id = BasicJob.perform_later.job_id
    good_job_class.where(active_job_id: job_id).update_all(scheduled_at: nil)
    assert_equal 1, HireFire::Macro::GoodJob.job_queue_size
    assert_equal 1, HireFire::Macro::GoodJob.job_queue_size(:default)
  end

  def test_job_queue_size_excludes_running_jobs
    job_id = BasicJob.perform_later.job_id
    mark_running(job_id, at: 1.minute.ago)
    assert_equal 0, HireFire::Macro::GoodJob.job_queue_size
  end

  def test_job_queue_size_excludes_finished_before_perform_without_discard_event
    job_id = Timecop.freeze(2.minutes.ago) { BasicJob.perform_later.job_id }
    mark_finished_before_perform(job_id, finished_at: 1.minute.ago, scheduled_at: 2.minutes.ago)
    assert_equal 0, HireFire::Macro::GoodJob.job_queue_size
  end

  def test_job_queue_size_with_discarded_jobs
    skip "GoodJob #{::GoodJob::VERSION} does not support error events" unless error_event_supported?
    job_id = Timecop.freeze(1.minute.ago) { BasicJob.perform_later.job_id }
    mark_discarded(job_id, at: 1.minute.ago)
    assert_equal 0, HireFire::Macro::GoodJob.job_queue_size
  end

  def test_job_queue_size_with_retried_jobs
    skip "GoodJob #{::GoodJob::VERSION} does not support error events" unless error_event_supported?
    job_id = Timecop.freeze(1.minute.ago) { BasicJob.perform_later.job_id }
    good_job_class.where(active_job_id: job_id).update_all(
      performed_at: nil,
      finished_at: nil,
      scheduled_at: 1.minute.ago,
      error_event: retried_enum
    )
    assert_equal 1, HireFire::Macro::GoodJob.job_queue_size
    mark_running(job_id, at: Time.now)
    assert_equal 0, HireFire::Macro::GoodJob.job_queue_size
  end

  def test_ready_queue_ignores_terminal_and_running_neighbors
    ready_id = Timecop.freeze(3.minutes.ago) { BasicJob.perform_later.job_id }
    running_id = Timecop.freeze(2.minutes.ago) { BasicJob.perform_later.job_id }
    finished_id = Timecop.freeze(4.minutes.ago) { BasicJob.perform_later.job_id }

    mark_running(running_id, at: 2.minutes.ago)
    mark_finished_before_perform(finished_id, finished_at: 1.minute.ago, scheduled_at: 4.minutes.ago)

    assert_equal 1, HireFire::Macro::GoodJob.job_queue_size
    assert_equal 1, HireFire::Macro::GoodJob.job_queue_size(:default)
    assert_in_delta 180, HireFire::Macro::GoodJob.job_queue_latency, LATENCY_DELTA

    remaining = good_job_class.where(active_job_id: ready_id).where(finished_at: nil, performed_at: nil)
    assert_equal 1, remaining.count
  end

  def test_finished_success_rows_are_excluded
    job_id = Timecop.freeze(5.minutes.ago) { BasicJob.perform_later.job_id }
    good_job_class.where(active_job_id: job_id).update_all(
      performed_at: 4.minutes.ago,
      finished_at: 3.minutes.ago,
      scheduled_at: 5.minutes.ago
    )
    assert_equal 0, HireFire::Macro::GoodJob.job_queue_size
    assert_equal 0, HireFire::Macro::GoodJob.job_queue_latency
  end

  def test_error_event_support_follows_schema_not_version
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

  def test_deprecated_queue_includes_running
    id = BasicJob.perform_later.job_id
    mark_running(id, at: Time.now)

    assert_equal 1, HireFire::Macro::GoodJob.queue(:default)
    assert_equal 0, HireFire::Macro::GoodJob.job_queue_size(:default)
  end

  def test_job_queue_working_idle_is_zero
    assert_equal 0, HireFire::Macro::GoodJob.job_queue_working
    assert_equal 0, HireFire::Macro::GoodJob.job_queue_working(:default)
  end

  def test_job_queue_working_counts_in_flight_and_filters_queues
    default_id = BasicJob.perform_later.job_id
    mailer_id = BasicJob.set(queue: :mailer).perform_later.job_id
    mark_running(default_id, at: Time.now)
    mark_running(mailer_id, at: Time.now)

    assert_equal 2, HireFire::Macro::GoodJob.job_queue_working
    assert_equal 1, HireFire::Macro::GoodJob.job_queue_working(:default)
    assert_equal 1, HireFire::Macro::GoodJob.job_queue_working(:mailer)
    assert_equal 0, HireFire::Macro::GoodJob.job_queue_working(:critical)
    assert_equal 2, HireFire::Macro::GoodJob.job_queue_working(:default, :mailer)
  end

  def test_job_queue_working_excludes_ready_and_finished
    ready_id = BasicJob.perform_later.job_id
    finished_id = BasicJob.set(queue: :mailer).perform_later.job_id
    running_id = BasicJob.set(queue: :other).perform_later.job_id
    mark_running(running_id, at: Time.now)
    good_job_class.where(active_job_id: finished_id).update_all(
      performed_at: 1.minute.ago,
      finished_at: Time.now
    )

    assert_equal 1, HireFire::Macro::GoodJob.job_queue_working
    assert_equal 0, HireFire::Macro::GoodJob.job_queue_working(:default)
    assert_equal 0, HireFire::Macro::GoodJob.job_queue_working(:mailer)
    assert_equal 1, HireFire::Macro::GoodJob.job_queue_working(:other)
    assert_equal 1, HireFire::Macro::GoodJob.job_queue_size(:default)
    assert_equal 0, HireFire::Macro::GoodJob.job_queue_size(:other)
    assert_equal 1, good_job_class.where(active_job_id: ready_id).count
  end

  def test_plan_execute_good_job_jqs_also_samples_wrk
    HireFire.configure { |c| c.logger = Logger.new(File::NULL) }
    buffer = HireFire.configuration.buffer
    buffer.flush

    running_id = BasicJob.perform_later.job_id
    mark_running(running_id, at: Time.now)
    BasicJob.perform_later

    HireFire::Plan.execute(
      "name" => "worker",
      "adapter" => "good_job",
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
    assert_equal HireFire::Macro::GoodJob.job_queue_working(:default), wrk_value
    assert_equal HireFire::Macro::GoodJob.job_queue_size(:default), jqs_value
    assert_operator wrk_value, :>, 0
  end

  def test_plan_execute_good_job_jql_also_samples_wrk
    HireFire.configure { |c| c.logger = Logger.new(File::NULL) }
    buffer = HireFire.configuration.buffer
    buffer.flush

    running_id = BasicJob.perform_later.job_id
    mark_running(running_id, at: Time.now)

    HireFire::Plan.execute(
      "name" => "worker",
      "adapter" => "good_job",
      "strategy" => "jql",
      "queues" => ["default"],
      "options" => {}
    )

    flushed = buffer.flush
    assert flushed.dig("worker", "jql")
    assert_equal 1, flushed.dig("worker", "wrk")&.values&.last
  end

  def test_plan_execute_good_job_empty_queues_samples_all_wrk
    HireFire.configure { |c| c.logger = Logger.new(File::NULL) }
    buffer = HireFire.configuration.buffer
    buffer.flush

    default_id = BasicJob.perform_later.job_id
    mailer_id = BasicJob.set(queue: :mailer).perform_later.job_id
    mark_running(default_id, at: Time.now)
    mark_running(mailer_id, at: Time.now)

    HireFire::Plan.execute(
      "name" => "worker",
      "adapter" => "good_job",
      "strategy" => "jqs",
      "queues" => [],
      "options" => {}
    )

    flushed = buffer.flush
    assert_equal 2, flushed.dig("worker", "wrk")&.values&.last
    assert_equal HireFire::Macro::GoodJob.job_queue_working, flushed.dig("worker", "wrk")&.values&.last
  end

  private

  def mark_running(job_id, at:)
    good_job_class.where(active_job_id: job_id).update_all(
      performed_at: at,
      finished_at: nil
    )
  end

  def mark_finished_before_perform(job_id, finished_at:, scheduled_at:)
    attrs = {
      performed_at: nil,
      finished_at: finished_at,
      scheduled_at: scheduled_at
    }
    attrs[:error_event] = nil if error_event_supported?
    good_job_class.where(active_job_id: job_id).update_all(attrs)
  end

  def mark_discarded(job_id, at:)
    attrs = {
      performed_at: nil,
      scheduled_at: at,
      finished_at: at
    }
    attrs[:error_event] = discarded_enum if error_event_supported?
    good_job_class.where(active_job_id: job_id).update_all(attrs)
  end

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
