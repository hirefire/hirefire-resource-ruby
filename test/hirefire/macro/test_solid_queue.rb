# frozen_string_literal: true

require "test_helper"

require_relative "../../env/rails_solid_queue_0/config/environment"

class HireFire::Macro::SolidQueueTest < Minitest::Test
  LATENCY_DELTA = 2

  def setup
    prepare_database
    SolidQueue.logger = Logger.new(File::NULL)
  end

  def test_job_queue_latency_without_jobs
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_latency(:default)
  end

  def test_job_queue_latency_with_jobs
    BasicJob.perform_later
    Timecop.freeze(1.minute.ago) { BasicJob.set(queue: :mailer).perform_later }
    assert_in_delta 0, HireFire::Macro::SolidQueue.job_queue_latency(:default), LATENCY_DELTA
    assert_in_delta 60, HireFire::Macro::SolidQueue.job_queue_latency(:default, :mailer), LATENCY_DELTA
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
      assert_in_delta 25, HireFire::Macro::SolidQueue.job_queue_latency, LATENCY_DELTA
      assert_in_delta 20, HireFire::Macro::SolidQueue.job_queue_latency(:default), LATENCY_DELTA
      assert_in_delta 25, HireFire::Macro::SolidQueue.job_queue_latency(:default, :mailer), LATENCY_DELTA
    end
  end

  def test_job_queue_latency_with_claimed_jobs
    Timecop.freeze(1.minute.ago) { insert_claimed_job(BasicJob) }
    assert_in_delta 0, HireFire::Macro::SolidQueue.job_queue_latency(:default), LATENCY_DELTA
    # Claimed jobs are not counted in latency.
  end

  def test_job_queue_size_without_jobs
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_size
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_size(:default)
    assert_equal 0, HireFire::Macro::SolidQueue.job_queue_size(:default, :mailer)
  end

  def test_job_queue_size_with_jobs
    BasicJob.perform_later
    BasicJob.set(queue: :mailer).perform_later
    BasicJob.set(queue: :mailer_notification).perform_later
    BasicJob.set(queue: :mailer_newsletter).perform_later
    assert_equal 4, HireFire::Macro::SolidQueue.job_queue_size
    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_size(:default)
    assert_equal 2, HireFire::Macro::SolidQueue.job_queue_size(:default, :mailer)
    assert_equal 3, HireFire::Macro::SolidQueue.job_queue_size(:"mailer*") # expand to mailer, mailer_notification, mailer_newsletter
    assert_equal 2, HireFire::Macro::SolidQueue.job_queue_size(:"mailer_*") # expand to mailer_notification, mailer_newsletter
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
      assert_equal 2, HireFire::Macro::SolidQueue.job_queue_size
      assert_equal 1, HireFire::Macro::SolidQueue.job_queue_size(:default)
      assert_equal 2, HireFire::Macro::SolidQueue.job_queue_size(:default, :mailer)
    end
  end

  def test_job_queue_size_with_claimed_jobs
    insert_claimed_job(BasicJob)
    insert_claimed_job(BasicJob, queue: :mailer)
    assert_equal 2, HireFire::Macro::SolidQueue.job_queue_size
    assert_equal 1, HireFire::Macro::SolidQueue.job_queue_size(:default)
    assert_equal 2, HireFire::Macro::SolidQueue.job_queue_size(:default, :mailer)
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

    SolidQueue::Job.delete_all # Cascades deletion to all executions.
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
    assert (job_count + 1), SolidQueue::Job.count
    assert_equal ready_count, SolidQueue::ReadyExecution.count
  end

  def insert_claimed_job(job_class, **options)
    job_count = SolidQueue::Job.count
    claimed_count = SolidQueue::ClaimedExecution.count
    ready_count = SolidQueue::ReadyExecution.count
    job = job_class.set(**options).perform_later
    process = SolidQueue::Process.create!(pid: 1, kind: "Worker", last_heartbeat_at: Time.now)
    SolidQueue::Job.transaction do
      SolidQueue::ReadyExecution.find_by(job_id: job.provider_job_id).destroy!
      SolidQueue::ClaimedExecution.create!(job_id: job.provider_job_id, process_id: process.id)
    end
    assert_equal (job_count + 1), SolidQueue::Job.count
    assert_equal (claimed_count + 1), SolidQueue::ClaimedExecution.count
    assert_equal ready_count, SolidQueue::ReadyExecution.count
  end

  def insert_blocked_job(job_class, **options)
    job_count = SolidQueue::Job.count
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
    assert (job_count + 1), SolidQueue::Job.count
    assert_equal ready_count, SolidQueue::ReadyExecution.count
  end
end
