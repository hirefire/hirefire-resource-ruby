# frozen_string_literal: true

require "test_helper"

class HireFire::Macro::ResqueTest < Minitest::Test
  def setup
    expire_cache!
    Resque.redis = Redis.new(db: 15).tap(&:flushdb)
  end

  def teardown
    Resque.redis.close
  end

  def expire_cache!
    HireFire::Macro::Resque.send(:cache).expire!
  end

  def test_job_queue_latency_unsupported
    assert_raises(HireFire::Errors::JobQueueLatencyUnsupportedError) do
      HireFire::Macro::Resque.job_queue_latency
    end
  end

  def test_job_queue_size_without_jobs
    assert_equal 0, HireFire::Macro::Resque.job_queue_size
  end

  def test_job_queue_size_with_jobs
    Resque.enqueue_to(:default, BasicJob)
    Resque.enqueue_to(:mailer, BasicJob)
    assert_equal 2, HireFire::Macro::Resque.job_queue_size
    assert_equal 1, HireFire::Macro::Resque.job_queue_size(:default)
    assert_equal 2, HireFire::Macro::Resque.job_queue_size(:default, :mailer)
  end

  def test_job_queue_size_with_working
    enqueue_to_working_with_queue :default, BasicJob
    assert_equal 1, HireFire::Macro::Resque.job_queue_size
    assert_equal 1, HireFire::Macro::Resque.job_queue_size(:default)
    assert_equal 0, HireFire::Macro::Resque.job_queue_size(:mailer)
  end

  def test_job_queue_size_with_scheduled_jobs
    Resque.enqueue_in_with_queue(:default, 100, BasicJob)
    Resque.enqueue_in_with_queue(:default, 300, BasicJob)
    Resque.enqueue_in_with_queue(:mailer, 300, BasicJob)

    assert_equal 0, HireFire::Macro::Resque.job_queue_size # uncached

    Timecop.freeze(Time.now + 200) do
      assert_equal 1, HireFire::Macro::Resque.job_queue_size # uncached
      assert_equal 1, HireFire::Macro::Resque.job_queue_size(:default) # uncached
      assert_equal 0, HireFire::Macro::Resque.job_queue_size(:mailer) # cached
      assert_equal 1, HireFire::Macro::Resque.job_queue_size(:default, :mailer) # cached
    end

    Timecop.freeze(Time.now + 400) do
      assert_equal 2, HireFire::Macro::Resque.job_queue_size(:default) # expired
      assert_equal 1, HireFire::Macro::Resque.job_queue_size(:mailer) # cached
      assert_equal 3, HireFire::Macro::Resque.job_queue_size(:default, :mailer) # cached
      assert_equal 3, HireFire::Macro::Resque.job_queue_size # cached
    end
  end

  def test_job_queue_size_failing_job_retries
    Resque.enqueue(FailingJob)

    assert_raises FailingJob::ExpectedError do
      Resque::Job.reserve(:default).perform
    end

    assert_equal 0, HireFire::Macro::Resque.job_queue_size

    Timecop.freeze(Time.now + FailingJob.retry_delay) do
      assert_equal 1, HireFire::Macro::Resque.job_queue_size
    end
  end

  def test_deprecated_queue_method
    Resque.enqueue_to(:default, BasicJob)
    assert_equal 1, HireFire::Macro::Resque.queue(:default)
  end

  def self.next_id
    @next_id ||= 0
    @next_id += 1
  end

  private

  class BasicJob
    def self.perform
    end
  end

  class FailingJob
    extend Resque::Plugins::Retry

    class ExpectedError < StandardError; end

    @queue = :default
    @retry_delay = 5
    @retry_limit = 1

    def self.perform
      raise ExpectedError
    end
  end

  def enqueue_to_working_with_queue(queue, job)
    self.class.next_id.tap do |id|
      worker = {
        queue: queue,
        payload: {
          class: job,
          args: []
        }
      }
      Resque.redis.pipelined do |pipeline|
        pipeline.set("worker:#{id}", Resque.encode(worker))
        pipeline.sadd(:workers, id)
      end
    end
  end
end
