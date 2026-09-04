# frozen_string_literal: true

require "test_helper"

class HireFire::Macro::ResqueTest < Minitest::Test
  def setup
    super
    Resque.redis = Redis.new(port: ENV.fetch("REDIS_PORT", 6379).to_i, db: 0).tap(&:flushdb)
  end

  def teardown
    Resque.redis.close
    super
  end

  def test_library_loaded_is_true_when_resque_gem_is_loaded
    assert HireFire::Plan.library_loaded?("resque")
    assert HireFire::Plan.executable?("resque")
    assert HireFire::Plan.any_allowlisted_job_queue_library_loaded?
  end

  def test_job_queue_latency_unsupported
    assert_raises(HireFire::Errors::JobQueueLatencyUnsupportedError) do
      HireFire::Macro::Resque.job_queue_latency
    end
  end

  def test_supports_plan_strategy_size_only
    refute HireFire::Macro::Resque.supports_plan_strategy?("jql")
    refute HireFire::Macro::Resque.supports_plan_strategy?(:jql)
    assert HireFire::Macro::Resque.supports_plan_strategy?("jqs")
    assert HireFire::Macro::Resque.supports_plan_strategy?(:jqs)
    refute HireFire::Macro::Resque.supports_plan_strategy?("rpm")
  end

  def test_does_not_define_job_queue_working
    refute HireFire::Macro::Resque.respond_to?(:job_queue_working)
  end

  def test_job_queue_size_without_jobs
    size = HireFire::Macro::Resque.job_queue_size
    assert_integer_count size
    assert_equal 0, size
  end

  def test_all_queues_ignores_orphan_queue_keys
    Resque.enqueue_to(:default, BasicJob)
    Resque.redis.lpush("queue:orphan", Resque.encode("class" => "BasicJob", "args" => []))
    refute_includes Resque.queues, "orphan"
    assert_equal 1, HireFire::Macro::Resque.job_queue_size
    assert_equal 1, HireFire::Macro::Resque.job_queue_size(:default)
  end

  def test_job_queue_size_with_jobs
    Resque.enqueue_to(:default, BasicJob)
    Resque.enqueue_to(:mailer, BasicJob)
    size = HireFire::Macro::Resque.job_queue_size
    assert_integer_count size
    assert_equal 2, size
    assert_equal 1, HireFire::Macro::Resque.job_queue_size(:default)
    assert_equal 2, HireFire::Macro::Resque.job_queue_size(:default, :mailer)
  end

  def test_job_queue_size_with_working
    enqueue_to_working_with_queue :default, BasicJob
    assert_equal 0, HireFire::Macro::Resque.job_queue_size
    assert_equal 0, HireFire::Macro::Resque.job_queue_size(:default)
    assert_equal 0, HireFire::Macro::Resque.job_queue_size(:mailer)
  end

  def test_job_queue_size_counts_live_and_due_only_with_working_present
    Resque.enqueue_to(:default, BasicJob)
    Resque.enqueue_to(:mailer, BasicJob)
    Resque.enqueue_in_with_queue(:default, -60, BasicJob)
    Resque.enqueue_in_with_queue(:mailer, 300, BasicJob)
    enqueue_to_working_with_queue :default, BasicJob
    enqueue_to_working_with_queue :other, BasicJob

    assert_equal 3, HireFire::Macro::Resque.job_queue_size
    assert_equal 2, HireFire::Macro::Resque.job_queue_size(:default)
    assert_equal 1, HireFire::Macro::Resque.job_queue_size(:mailer)
    assert_equal 0, HireFire::Macro::Resque.job_queue_size(:other)
    assert_equal 3, HireFire::Macro::Resque.job_queue_size(:default, :mailer)
  end

  def test_job_queue_size_with_scheduled_jobs
    Resque.enqueue_in_with_queue(:default, 100, BasicJob)
    Resque.enqueue_in_with_queue(:default, 300, BasicJob)
    Resque.enqueue_in_with_queue(:mailer, 300, BasicJob)

    assert_equal 0, HireFire::Macro::Resque.job_queue_size

    Timecop.freeze(Time.now + 200) do
      assert_equal 1, HireFire::Macro::Resque.job_queue_size
      assert_equal 1, HireFire::Macro::Resque.job_queue_size(:default)
      assert_equal 0, HireFire::Macro::Resque.job_queue_size(:mailer)
      assert_equal 1, HireFire::Macro::Resque.job_queue_size(:default, :mailer)
    end

    Timecop.freeze(Time.now + 400) do
      assert_equal 3, HireFire::Macro::Resque.job_queue_size
      assert_equal 2, HireFire::Macro::Resque.job_queue_size(:default)
      assert_equal 1, HireFire::Macro::Resque.job_queue_size(:mailer)
      assert_equal 3, HireFire::Macro::Resque.job_queue_size(:default, :mailer)
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

  def test_job_queue_size_pages_scheduled_timestamps_across_the_batch_boundary
    now = Time.now.to_i

    Resque.redis.pipelined do |pipeline|
      1_001.times do |i|
        timestamp = now - 2_000 + i
        pipeline.zadd("delayed_queue_schedule", timestamp, timestamp)
        pipeline.rpush("delayed:#{timestamp}", Resque.encode("class" => "BasicJob", "args" => [], "queue" => "default"))
      end
    end

    assert_equal 1_001, HireFire::Macro::Resque.job_queue_size
  end

  def test_job_queue_size_pages_scheduled_jobs_within_a_timestamp_across_the_batch_boundary
    timestamp = Time.now.to_i - 100

    Resque.redis.pipelined do |pipeline|
      pipeline.zadd("delayed_queue_schedule", timestamp, timestamp)
      1_500.times do |i|
        queue = (i % 3 == 0) ? "mailer" : "default"
        pipeline.rpush("delayed:#{timestamp}", Resque.encode("class" => "BasicJob", "args" => [], "queue" => queue))
      end
    end

    assert_equal 1_000, HireFire::Macro::Resque.job_queue_size(:default)
    assert_equal 500, HireFire::Macro::Resque.job_queue_size(:mailer)
  end

  def test_job_queue_size_skips_corrupt_delayed_payloads
    timestamp = Time.now.to_i - 10
    Resque.redis.zadd("delayed_queue_schedule", timestamp, timestamp)
    Resque.redis.rpush("delayed:#{timestamp}", "not-json")
    Resque.redis.rpush("delayed:#{timestamp}", "null")
    Resque.redis.rpush(
      "delayed:#{timestamp}",
      Resque.encode("class" => "BasicJob", "args" => [], "queue" => "default")
    )

    assert_equal 1, HireFire::Macro::Resque.job_queue_size(:default)
    assert_equal 3, HireFire::Macro::Resque.job_queue_size
  end

  def test_named_delayed_walk_raises_instead_of_undercounting_when_budget_is_exceeded
    timestamp = Time.now.to_i - 10
    Resque.redis.zadd("delayed_queue_schedule", timestamp, timestamp)
    Resque.redis.pipelined do |pipeline|
      20.times do
        pipeline.rpush(
          "delayed:#{timestamp}",
          Resque.encode("class" => "BasicJob", "args" => [], "queue" => "default")
        )
      end
    end

    stub_resque_const(:WALK_JOB_BUDGET, 5) do
      assert_raises(HireFire::Errors::SampleIncomplete) do
        HireFire::Macro::Resque.job_queue_size(:default)
      end
    end
  end

  def stub_resque_const(name, value)
    mod = HireFire::Macro::Resque
    original = mod.const_get(name)
    mod.send(:remove_const, name)
    mod.const_set(name, value)
    yield
  ensure
    mod.send(:remove_const, name)
    mod.const_set(name, original)
  end

  def test_all_queues_counts_delayed_payloads_for_unregistered_queues
    timestamp = Time.now.to_i - 10
    Resque.redis.zadd("delayed_queue_schedule", timestamp, timestamp)
    Resque.redis.rpush(
      "delayed:#{timestamp}",
      Resque.encode("class" => "BasicJob", "args" => [], "queue" => "never_registered")
    )

    refute_includes Resque.queues, "never_registered"
    assert_equal 1, HireFire::Macro::Resque.job_queue_size
    assert_equal 0, HireFire::Macro::Resque.job_queue_size(:default)
  end

  def test_deprecated_queue_method
    Resque.enqueue_to(:default, BasicJob)
    assert_equal 1, HireFire::Macro::Resque.queue(:default)
  end

  def test_deprecated_queue_still_includes_working
    enqueue_to_working_with_queue :default, BasicJob
    assert_equal 1, HireFire::Macro::Resque.queue(:default)
    assert_equal 0, HireFire::Macro::Resque.job_queue_size(:default)
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
