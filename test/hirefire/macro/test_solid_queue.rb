# frozen_string_literal: true

require "test_helper"
require "support/own_pool"
require "solid_queue/version"

class HireFire::Macro::SolidQueueTest < Minitest::Test
  include OwnPool

  MAJOR_VERSION = Gem::Version.new(::SolidQueue::VERSION).segments[0]
  require_relative "../../env/rails_solid_queue_#{MAJOR_VERSION}/config/environment"

  LATENCY_DELTA = 2

  def setup
    super
    prepare_database
    SolidQueue.logger = Logger.new(File::NULL)
  end

  def teardown
    HireFire::Macro::SolidQueue.reinit_after_fork
    super
  end

  def test_library_loaded_is_true_when_solid_queue_gem_is_loaded
    assert HireFire::Macro::SolidQueue.library_loaded?
    assert HireFire::Plan.any_library_loaded?
  end

  def test_job_queue_latency_without_jobs
    latency = HireFire::Macro::SolidQueue.job_queue_latency(:default)
    assert_float_seconds latency
    assert_equal 0, latency
  end

  def test_job_queue_latency_clamps_future_created_at_to_zero
    BasicJob.perform_later
    ::SolidQueue::ReadyExecution.where(queue_name: "default").update_all(created_at: 1.minute.from_now)
    assert_equal 0.0, HireFire::Macro::SolidQueue.job_queue_latency(:default)
  end

  def test_the_paused_queues_are_read_once_in_a_round_and_on_every_call_outside_one
    BasicJob.perform_later
    BasicJob.set(queue: :mailer).perform_later
    reads = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      reads += 1 if payload[:sql].match?(/\ASELECT "solid_queue_pauses"."queue_name" FROM/)
    end

    HireFire::Macro::SolidQueue.before_sample_job_queues
    assert_equal 2, HireFire::Macro::SolidQueue.job_queue_size
    pause_queue("mailer")
    assert_equal 2, HireFire::Macro::SolidQueue.job_queue_size
    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_size(:mailer)
    HireFire::Macro::SolidQueue.after_sample_job_queues

    assert_equal 1, reads
    reads = 0
    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_size
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_size(:mailer)
    assert_equal 2, reads
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def test_a_new_round_reads_the_paused_queues_again
    BasicJob.perform_later
    BasicJob.set(queue: :mailer).perform_later

    HireFire::Macro::SolidQueue.before_sample_job_queues
    assert_equal 2, HireFire::Macro::SolidQueue.job_queue_size
    pause_queue("mailer")
    HireFire::Macro::SolidQueue.before_sample_job_queues

    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_size
  end

  def test_the_queue_names_are_read_again_after_sixty_seconds_and_not_before
    BasicJob.perform_later
    HireFire::Clock.stubs(:monotonic).returns(1_000.0)
    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_size
    BasicJob.set(queue: :mailer).perform_later

    HireFire::Clock.stubs(:monotonic).returns(1_059.9)
    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_size
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_size(:"mail*")
    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_size(:mailer)

    HireFire::Clock.stubs(:monotonic).returns(1_060.0)
    assert_equal 2, HireFire::Macro::SolidQueue.job_queue_size
    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_size(:"mail*")
    assert_equal 60.0, HireFire::Macro::SolidQueue::REGISTERED_QUEUE_TTL
  end

  def test_a_fork_reset_reads_the_queue_names_again
    BasicJob.perform_later
    HireFire::Clock.stubs(:monotonic).returns(1_000.0)
    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_size
    BasicJob.set(queue: :mailer).perform_later

    HireFire::Macro::SolidQueue.reinit_after_fork

    assert_equal 2, HireFire::Macro::SolidQueue.job_queue_size
  end

  def test_a_sample_leaves_the_primary_pool_alone_when_the_jobs_have_their_own_pool
    checkouts = primary_checkouts_while_on_its_own_pool(SolidQueue::Record) do
      HireFire::Macro::SolidQueue.job_queue_size
      HireFire::Macro::SolidQueue.job_queue_size(skip_working: true)
      HireFire::Macro::SolidQueue.job_queue_latency
      HireFire::Macro::SolidQueue.job_queue_working
    end

    assert_equal 0, checkouts
  end

  def test_job_queue_latency_with_jobs
    BasicJob.perform_later
    Timecop.freeze(1.minute.ago) { BasicJob.set(queue: :mailer).perform_later }
    assert_in_delta 0, HireFire::Macro::SolidQueue.job_queue_latency(:default), LATENCY_DELTA
    latency = HireFire::Macro::SolidQueue.job_queue_latency(:default, :mailer)
    assert_float_seconds latency
    assert_in_delta 60, latency, LATENCY_DELTA
  end

  def test_job_queue_latency_with_scheduled_job
    Timecop.freeze(1.minute.ago) do
      BasicJob.set(wait_until: 2.minutes.from_now).perform_later
      BasicJob.set(queue: :mailer, wait_until: 1.second.from_now).perform_later
    end
    assert_in_delta 0, HireFire::Macro::SolidQueue.job_queue_latency(:default), LATENCY_DELTA
    assert_in_delta 60, HireFire::Macro::SolidQueue.job_queue_latency(:mailer), LATENCY_DELTA
  end

  def test_job_queue_latency_with_finished_jobs
    Timecop.freeze(1.minute.ago) { insert_finished_job(BasicJob) }
    assert_in_delta 0, HireFire::Macro::SolidQueue.job_queue_latency(:default), LATENCY_DELTA
  end

  def test_job_queue_latency_with_blocked_jobs
    insert_blocked_job(BlockedJob)
    Timecop.freeze(5.seconds.ago) do
      insert_blocked_job(BlockedJob, queue: :mailer)
    end
    Timecop.freeze(5.seconds.from_now) do
      assert_in_delta 0, HireFire::Macro::SolidQueue.job_queue_latency, LATENCY_DELTA
      assert_in_delta 0, HireFire::Macro::SolidQueue.job_queue_latency(:default), LATENCY_DELTA
      assert_in_delta 0, HireFire::Macro::SolidQueue.job_queue_latency(:default, :mailer), LATENCY_DELTA
    end
    Timecop.freeze(30.seconds.from_now) do
      assert_in_delta 0, HireFire::Macro::SolidQueue.job_queue_latency, LATENCY_DELTA
      assert_in_delta 0, HireFire::Macro::SolidQueue.job_queue_latency(:default), LATENCY_DELTA
      assert_in_delta 0, HireFire::Macro::SolidQueue.job_queue_latency(:default, :mailer), LATENCY_DELTA
    end
  end

  def test_job_queue_latency_with_claimed_jobs
    Timecop.freeze(1.minute.ago) { insert_claimed_job(BasicJob) }
    assert_in_delta 0, HireFire::Macro::SolidQueue.job_queue_latency(:default), LATENCY_DELTA
  end

  def test_job_queue_latency_ignores_claimed_and_blocked_when_ready_exists
    Timecop.freeze(2.minutes.ago) { insert_claimed_job(BasicJob) }
    Timecop.freeze(3.minutes.ago) { insert_blocked_job(BlockedJob, queue: :mailer) }
    Timecop.freeze(1.minute.ago) { BasicJob.set(queue: :other).perform_later }
    Timecop.freeze(4.minutes.ago) do
      BasicJob.set(queue: :mailer_notification, wait_until: 1.second.from_now).perform_later
    end

    assert_in_delta 240, HireFire::Macro::SolidQueue.job_queue_latency, LATENCY_DELTA
    assert_in_delta 0, HireFire::Macro::SolidQueue.job_queue_latency(:default), LATENCY_DELTA
    assert_in_delta 0, HireFire::Macro::SolidQueue.job_queue_latency(:mailer), LATENCY_DELTA
    assert_in_delta 60, HireFire::Macro::SolidQueue.job_queue_latency(:other), LATENCY_DELTA
    assert_in_delta 240, HireFire::Macro::SolidQueue.job_queue_latency(:mailer_notification), LATENCY_DELTA
  end

  def test_job_queue_latency_with_paused_queues
    Timecop.freeze(1.minute.ago) { BasicJob.perform_later }
    Timecop.freeze(2.minutes.ago) { BasicJob.set(queue: :mailer).perform_later }

    assert_in_delta 120, HireFire::Macro::SolidQueue.job_queue_latency, LATENCY_DELTA

    pause_queue(:mailer)
    assert_in_delta 60, HireFire::Macro::SolidQueue.job_queue_latency, LATENCY_DELTA
    assert_in_delta 0, HireFire::Macro::SolidQueue.job_queue_latency(:mailer), LATENCY_DELTA

    resume_queue(:mailer)
    assert_in_delta 120, HireFire::Macro::SolidQueue.job_queue_latency, LATENCY_DELTA
  end

  def test_job_queue_latency_with_wildcard_queues
    Timecop.freeze(1.minute.ago) { BasicJob.set(queue: :mailer_notification).perform_later }
    Timecop.freeze(2.minutes.ago) { BasicJob.set(queue: :mailer_newsletter).perform_later }
    Timecop.freeze(30.seconds.ago) { BasicJob.set(queue: :other).perform_later }

    assert_in_delta 120, HireFire::Macro::SolidQueue.job_queue_latency(:"mailer_*"), LATENCY_DELTA
  end

  def test_job_queue_size_without_jobs
    size = HireFire::Macro::SolidQueue.job_queue_size
    assert_integer_count size
    assert_equal 0, size
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_size(:default)
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_size(:default, :mailer)
  end

  def test_job_queue_size_with_jobs
    BasicJob.perform_later
    BasicJob.set(queue: :mailer).perform_later
    BasicJob.set(queue: :mailer_notification).perform_later
    BasicJob.set(queue: :mailer_newsletter).perform_later
    size = HireFire::Macro::SolidQueue.job_queue_size
    assert_integer_count size
    assert_equal 4, size
    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_size(:default)
    assert_equal 2, HireFire::Macro::SolidQueue.job_queue_size(:default, :mailer)
    assert_equal 3, HireFire::Macro::SolidQueue.job_queue_size(:"mailer*")
    assert_equal 2, HireFire::Macro::SolidQueue.job_queue_size(:"mailer_*")
  end

  def test_job_queue_size_with_paused_queues
    BasicJob.perform_later
    BasicJob.set(queue: :mailer).perform_later
    pause_queue(:default)
    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_size
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_size(:default)
    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_size(:default, :mailer)
    pause_queue(:mailer)
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_size
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_size(:default)
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_size(:default, :mailer)
    resume_queue(:default)
    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_size
    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_size(:default)
    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_size(:default, :mailer)
  end

  def test_job_queue_size_with_scheduled_jobs
    BasicJob.set(wait_until: 1.minute.ago).perform_later
    BasicJob.set(queue: :mailer, wait_until: 1.minute.ago).perform_later
    BasicJob.set(wait_until: 1.minute.from_now).perform_later
    BasicJob.set(queue: :mailer, wait_until: 1.minute.from_now).perform_later
    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_size(:default)
    assert_equal 2, HireFire::Macro::SolidQueue.job_queue_size(:default, :mailer)
  end

  def test_job_queue_size_counts_scheduled_jobs_that_became_due_in_their_own_queue
    Timecop.freeze(5.minutes.ago) do
      BasicJob.set(wait_until: 3.minutes.from_now).perform_later
      2.times { BasicJob.set(queue: :mailer, wait_until: 2.minutes.from_now).perform_later }
    end
    BasicJob.perform_later

    assert_equal 3, ::SolidQueue::ScheduledExecution.count
    assert_equal 2, HireFire::Macro::SolidQueue.job_queue_size(:default)
    assert_equal 2, HireFire::Macro::SolidQueue.job_queue_size(:mailer)
    assert_equal 4, HireFire::Macro::SolidQueue.job_queue_size
    assert_in_delta 180, HireFire::Macro::SolidQueue.job_queue_latency(:mailer), LATENCY_DELTA
    assert_in_delta 120, HireFire::Macro::SolidQueue.job_queue_latency(:default), LATENCY_DELTA
  end

  def test_a_queue_name_without_a_wildcard_is_matched_exactly
    BasicJob.set(queue: :mail).perform_later
    2.times { BasicJob.set(queue: :mailer).perform_later }

    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_size(:mail)
    assert_equal 2, HireFire::Macro::SolidQueue.job_queue_size(:mailer)
    assert_equal 3, HireFire::Macro::SolidQueue.job_queue_size(:"mail*")
  end

  def test_job_queue_size_with_finished_jobs
    insert_finished_job(BasicJob)
    insert_finished_job(BasicJob, queue: :mailer)
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_size
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_size(:default)
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_size(:default, :mailer)
  end

  def test_job_queue_size_with_blocked_jobs
    insert_blocked_job(BlockedJob)
    insert_blocked_job(BlockedJob, queue: :mailer)
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_size
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_size(:default)
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_size(:default, :mailer)
    Timecop.freeze(15.seconds.from_now) do
      assert_equal 0, HireFire::Macro::SolidQueue.job_queue_size
      assert_equal 0, HireFire::Macro::SolidQueue.job_queue_size(:default)
      assert_equal 0, HireFire::Macro::SolidQueue.job_queue_size(:default, :mailer)
    end
  end

  def test_job_queue_size_with_mixed_literal_and_wildcard_queues
    BasicJob.perform_later
    BasicJob.set(queue: :mailer_notification).perform_later
    BasicJob.set(queue: :mailer_newsletter).perform_later
    BasicJob.set(queue: :other).perform_later

    assert_equal 3, HireFire::Macro::SolidQueue.job_queue_size(:default, :"mailer_*")
  end

  def test_job_queue_size_counts_claimed_jobs_by_default
    insert_claimed_job(BasicJob)
    insert_claimed_job(BasicJob, queue: :mailer)
    assert_equal 2, HireFire::Macro::SolidQueue.job_queue_size
    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_size(:default)
    assert_equal 2, HireFire::Macro::SolidQueue.job_queue_size(:default, :mailer)
    assert_equal 2, HireFire::Macro::SolidQueue.job_queue_size(skip_working: false)
    assert_equal 2, HireFire::Macro::SolidQueue.job_queue_size(skip_working: nil)
  end

  def test_job_queue_size_skip_working_leaves_claimed_jobs_out
    insert_claimed_job(BasicJob)
    insert_claimed_job(BasicJob, queue: :mailer)
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_size(skip_working: true)
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_size(:default, skip_working: true)
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_size(:default, :mailer, skip_working: true)
  end

  def test_job_queue_size_with_ready_due_future_claimed_and_blocked_jobs
    BasicJob.perform_later
    BasicJob.set(queue: :mailer).perform_later
    BasicJob.set(wait_until: 1.minute.ago).perform_later
    BasicJob.set(wait_until: 1.minute.from_now).perform_later
    insert_claimed_job(BasicJob, queue: :other)
    insert_blocked_job(BlockedJob, queue: :mailer_notification)

    assert_equal 4, HireFire::Macro::SolidQueue.job_queue_size
    assert_equal 2, HireFire::Macro::SolidQueue.job_queue_size(:default)
    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_size(:mailer)
    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_size(:other)
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_size(:mailer_notification)

    assert_equal 3, HireFire::Macro::SolidQueue.job_queue_size(skip_working: true)
    assert_equal 2, HireFire::Macro::SolidQueue.job_queue_size(:default, skip_working: true)
    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_size(:mailer, skip_working: true)
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_size(:other, skip_working: true)
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_size(:mailer_notification, skip_working: true)
  end

  def test_job_queue_size_leaves_claimed_jobs_of_a_paused_queue_out
    insert_claimed_job(BasicJob)
    insert_claimed_job(BasicJob, queue: :mailer)
    pause_queue(:default)

    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_size
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_size(:default)
    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_size(:mailer)
  end

  def test_job_queue_working_idle_is_zero
    working = HireFire::Macro::SolidQueue.job_queue_working
    assert_integer_count working
    assert_equal 0, working
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_working(:default)
  end

  def test_job_queue_working_counts_in_flight_and_filters_queues
    insert_claimed_job(BasicJob)
    insert_claimed_job(BasicJob, queue: :mailer)

    working = HireFire::Macro::SolidQueue.job_queue_working
    assert_integer_count working
    assert_equal 2, working
    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_working(:default)
    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_working(:mailer)
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_working(:critical)
    assert_equal 2, HireFire::Macro::SolidQueue.job_queue_working(:default, :mailer)
  end

  def test_job_queue_working_excludes_paused_queues
    insert_claimed_job(BasicJob)
    insert_claimed_job(BasicJob, queue: :mailer)
    pause_queue(:default)

    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_working
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_working(:default)
    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_working(:mailer)
  end

  def test_job_queue_working_expands_wildcards
    insert_claimed_job(BasicJob, queue: :mailer)
    insert_claimed_job(BasicJob, queue: :mailer_notification)
    insert_claimed_job(BasicJob, queue: :critical)

    assert_equal 2, HireFire::Macro::SolidQueue.job_queue_working(:"mailer*")
    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_working(:"mailer_*")
  end

  def test_job_queue_working_excludes_ready_and_blocked
    BasicJob.perform_later
    insert_blocked_job(BlockedJob, queue: :mailer)
    insert_claimed_job(BasicJob, queue: :other)

    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_working
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_working(:default)
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_working(:mailer)
    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_working(:other)
    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_size(:other)
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_size(:other, skip_working: true)
  end

  def test_plan_execute_solid_queue_jqs_counts_running_jobs_and_samples_no_wrk
    HireFire.configure { |c| c.logger = Logger.new(File::NULL) }
    buffer = HireFire.configuration.buffer
    buffer.flush

    insert_claimed_job(BasicJob)
    BasicJob.perform_later

    sample_plan(
      "name" => "worker",
      "adapter" => "solid_queue",
      "strategy" => "jqs",
      "queues" => ["default"],
      "options" => {}
    )

    flushed = buffer.flush
    assert flushed["worker"], "plan must buffer under process name"
    assert flushed["worker"]["jqs"], "plan must sample jqs"
    assert_nil flushed["worker"]["wrk"], "plan must sample no wrk when the size holds the running jobs"

    jqs_value = flushed["worker"]["jqs"].values.last
    working = HireFire::Macro::SolidQueue.job_queue_working(:default)
    assert_kind_of Numeric, jqs_value
    assert_equal HireFire::Macro::SolidQueue.job_queue_size(:default), jqs_value
    assert_operator working, :>, 0
    assert_equal jqs_value, HireFire::Macro::SolidQueue.job_queue_size(:default, skip_working: true) + working
  end

  def test_plan_execute_skip_working_true_leaves_running_jobs_out_and_still_records_wrk
    HireFire.configure { |c| c.logger = Logger.new(File::NULL) }
    buffer = HireFire.configuration.buffer
    buffer.flush

    insert_claimed_job(BasicJob)
    BasicJob.perform_later

    sample_plan(
      "name" => "worker",
      "adapter" => "solid_queue",
      "strategy" => "jqs",
      "queues" => ["default"],
      "options" => {"skip_working" => true}
    )

    flushed = buffer.flush
    assert_equal 1, flushed.dig("worker", "jqs")&.values&.last
    assert_equal 1, flushed.dig("worker", "wrk")&.values&.last
  end

  def test_plan_execute_solid_queue_jql_also_samples_wrk
    HireFire.configure { |c| c.logger = Logger.new(File::NULL) }
    buffer = HireFire.configuration.buffer
    buffer.flush

    insert_claimed_job(BasicJob)

    sample_plan(
      "name" => "worker",
      "adapter" => "solid_queue",
      "strategy" => "jql",
      "queues" => ["default"],
      "options" => {}
    )

    flushed = buffer.flush
    assert flushed.dig("worker", "jql")
    assert_equal 1, flushed.dig("worker", "wrk")&.values&.last
  end

  def test_plan_execute_solid_queue_empty_queues_samples_all_wrk
    HireFire.configure { |c| c.logger = Logger.new(File::NULL) }
    buffer = HireFire.configuration.buffer
    buffer.flush

    insert_claimed_job(BasicJob)
    insert_claimed_job(BasicJob, queue: :mailer)

    sample_plan(
      "name" => "worker",
      "adapter" => "solid_queue",
      "strategy" => "jqs",
      "queues" => [],
      "options" => {"skip_working" => true}
    )

    flushed = buffer.flush
    assert_equal 2, flushed.dig("worker", "wrk")&.values&.last
    assert_equal HireFire::Macro::SolidQueue.job_queue_working, flushed.dig("worker", "wrk")&.values&.last
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

    SolidQueue::Job.delete_all
    SolidQueue::Pause.delete_all
  end

  def pause_queue(queue_name)
    SolidQueue::Queue.new(queue_name).pause
  end

  def resume_queue(queue_name)
    SolidQueue::Queue.new(queue_name).resume
  end

  def insert_finished_job(job_class, **options)
    job_count = SolidQueue::Job.count
    ready_count = SolidQueue::ReadyExecution.count
    job = job_class.set(**options).perform_later
    SolidQueue::Job.transaction do
      SolidQueue::ReadyExecution.find_by(job_id: job.provider_job_id).destroy
      SolidQueue::Job.find(job.provider_job_id).update!(finished_at: Time.now)
    end
    assert_equal job_count + 1, SolidQueue::Job.count
    assert_equal ready_count, SolidQueue::ReadyExecution.count
  end

  def insert_claimed_job(job_class, **options)
    job_count = SolidQueue::Job.count
    claimed_count = SolidQueue::ClaimedExecution.count
    ready_count = SolidQueue::ReadyExecution.count
    job = job_class.set(**options).perform_later

    process = SolidQueue::Process.create!(
      pid: 1,
      kind: "Worker",
      last_heartbeat_at: Time.now,
      name: "test-worker-1"
    )

    SolidQueue::Job.transaction do
      SolidQueue::ReadyExecution.find_by(job_id: job.provider_job_id).destroy!
      SolidQueue::ClaimedExecution.create!(job_id: job.provider_job_id, process_id: process.id)
    end

    assert_equal job_count + 1, SolidQueue::Job.count
    assert_equal claimed_count + 1, SolidQueue::ClaimedExecution.count
    assert_equal ready_count, SolidQueue::ReadyExecution.count
  end

  def insert_blocked_job(job_class, **options)
    job_count = SolidQueue::Job.count
    blocked_count = SolidQueue::BlockedExecution.count
    ready_count = SolidQueue::ReadyExecution.count
    job = job_class.set(**options).perform_later
    SolidQueue::Job.transaction do
      SolidQueue::ReadyExecution.where(job_id: job.provider_job_id).destroy_all
      SolidQueue::BlockedExecution.where(job_id: job.provider_job_id).destroy_all
      SolidQueue::BlockedExecution.create!(
        job_id: job.provider_job_id,
        queue_name: job.queue_name,
        priority: job.priority,
        concurrency_key: job.concurrency_key,
        expires_at: BlockedJob::BLOCK_DURATION.from_now
      )
    end
    assert_equal job_count + 1, SolidQueue::Job.count
    assert_equal blocked_count + 1, SolidQueue::BlockedExecution.count
    assert_equal ready_count, SolidQueue::ReadyExecution.count
  end
end
