# frozen_string_literal: true

require "test_helper"

class HireFire::Macro::ResqueTest < Minitest::Test
  def setup
    super
    Resque.redis = Redis.new(host: "127.0.0.1", port: ENV.fetch("REDIS_PORT", 6379).to_i, db: 0).tap(&:flushdb)
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

  def test_job_queue_working_without_jobs
    working = HireFire::Macro::Resque.job_queue_working
    assert_integer_count working
    assert_equal 0, working
    assert_equal 0, HireFire::Macro::Resque.job_queue_working(:default)
  end

  def test_job_queue_working_counts_the_jobs_workers_hold
    Resque.enqueue_to(:default, BasicJob)
    enqueue_to_working_with_queue :default, BasicJob
    enqueue_to_working_with_queue :default, BasicJob
    enqueue_to_working_with_queue :mailer, BasicJob

    assert_equal 3, HireFire::Macro::Resque.job_queue_working
    assert_equal 2, HireFire::Macro::Resque.job_queue_working(:default)
    assert_equal 1, HireFire::Macro::Resque.job_queue_working("mailer")
    assert_equal 3, HireFire::Macro::Resque.job_queue_working([:default, ["mailer"]])
    assert_equal 0, HireFire::Macro::Resque.job_queue_working(:other)
  end

  def test_job_queue_working_is_what_job_queue_size_adds
    Resque.enqueue_to(:default, BasicJob)
    enqueue_to_working_with_queue :default, BasicJob
    enqueue_to_working_with_queue :mailer, BasicJob
    heartbeat enqueue_to_working_with_queue(:default, BasicJob), Resque.prune_interval + 60
    macro = HireFire::Macro::Resque

    [[], [:default], [:mailer], [:default, :mailer]].each do |queues|
      added = macro.job_queue_size(*queues) - macro.job_queue_size(*queues, skip_working: true)
      assert_equal added, macro.job_queue_working(*queues)
    end
    assert_equal 2, macro.job_queue_working
  end

  def test_working_leaves_out_a_worker_whose_heartbeat_has_expired
    heartbeat enqueue_to_working_with_queue(:default, BasicJob), Resque.prune_interval + 60
    enqueue_to_working_with_queue :default, BasicJob

    assert_equal 1, HireFire::Macro::Resque.job_queue_working
    assert_equal 1, HireFire::Macro::Resque.job_queue_working(:default)
    assert_equal 1, HireFire::Macro::Resque.job_queue_size
    assert_equal 1, HireFire::Macro::Resque.job_queue_size(:default)
    assert_equal 1, HireFire::Macro::Resque.queue(:default)
  end

  def test_working_counts_a_worker_with_a_fresh_heartbeat
    heartbeat enqueue_to_working_with_queue(:default, BasicJob), 30

    assert_equal 1, HireFire::Macro::Resque.job_queue_working
    assert_equal 1, HireFire::Macro::Resque.job_queue_size(:default)
  end

  def test_working_counts_a_worker_without_a_heartbeat
    heartbeat enqueue_to_working_with_queue(:mailer, BasicJob), 30
    enqueue_to_working_with_queue :default, BasicJob

    assert_equal 1, HireFire::Macro::Resque.job_queue_working(:default)
    assert_equal 2, HireFire::Macro::Resque.job_queue_working
  end

  def test_working_counts_a_worker_whose_heartbeat_cannot_be_read
    worker = enqueue_to_working_with_queue :default, BasicJob
    Resque.redis.hset("workers:heartbeat", worker, "not-a-time")

    assert_equal 1, HireFire::Macro::Resque.job_queue_working
  end

  def test_working_follows_the_resque_prune_interval
    heartbeat enqueue_to_working_with_queue(:default, BasicJob), 120
    assert_equal 1, HireFire::Macro::Resque.job_queue_working

    original = Resque.prune_interval
    Resque.prune_interval = 60
    assert_equal 0, HireFire::Macro::Resque.job_queue_working
  ensure
    Resque.prune_interval = original if original
  end

  def test_working_leaves_out_the_workers_resque_itself_treats_as_dead
    job = {"class" => "BasicJob", "args" => []}
    alive = Resque::Worker.new(:default)
    dead = Resque::Worker.new(:mailer)
    silent = Resque::Worker.new(:other)
    [alive, dead, silent].each do |worker|
      worker.register_worker
      worker.working_on(Resque::Job.new(worker.queues.first, job))
    end
    alive.heartbeat!
    dead.heartbeat!(Resque.data_store.server_time - Resque.prune_interval - 60)

    assert_equal [dead.to_s], Resque::Worker.all_workers_with_expired_heartbeats.map(&:to_s)
    assert_equal 2, HireFire::Macro::Resque.job_queue_working
    assert_equal 1, HireFire::Macro::Resque.job_queue_working(:default)
    assert_equal 0, HireFire::Macro::Resque.job_queue_working(:mailer)
    assert_equal 1, HireFire::Macro::Resque.job_queue_working(:other)
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

  def test_job_queue_size_counts_working_jobs_by_default
    enqueue_to_working_with_queue :default, BasicJob
    assert_equal 1, HireFire::Macro::Resque.job_queue_size
    assert_equal 1, HireFire::Macro::Resque.job_queue_size(:default)
    assert_equal 0, HireFire::Macro::Resque.job_queue_size(:mailer)
    assert_equal 1, HireFire::Macro::Resque.job_queue_size(skip_working: false)
    assert_equal 1, HireFire::Macro::Resque.job_queue_size(skip_working: nil)
  end

  def test_job_queue_size_skip_working_leaves_working_jobs_out
    enqueue_to_working_with_queue :default, BasicJob
    assert_equal 0, HireFire::Macro::Resque.job_queue_size(skip_working: true)
    assert_equal 0, HireFire::Macro::Resque.job_queue_size(:default, skip_working: true)
  end

  def test_job_queue_size_with_live_due_future_and_working_jobs
    Resque.enqueue_to(:default, BasicJob)
    Resque.enqueue_to(:mailer, BasicJob)
    Resque.enqueue_in_with_queue(:default, -60, BasicJob)
    Resque.enqueue_in_with_queue(:mailer, 300, BasicJob)
    enqueue_to_working_with_queue :default, BasicJob
    enqueue_to_working_with_queue :other, BasicJob

    assert_equal 5, HireFire::Macro::Resque.job_queue_size
    assert_equal 3, HireFire::Macro::Resque.job_queue_size(:default)
    assert_equal 1, HireFire::Macro::Resque.job_queue_size(:mailer)
    assert_equal 1, HireFire::Macro::Resque.job_queue_size(:other)
    assert_equal 4, HireFire::Macro::Resque.job_queue_size(:default, :mailer)

    assert_equal 3, HireFire::Macro::Resque.job_queue_size(skip_working: true)
    assert_equal 2, HireFire::Macro::Resque.job_queue_size(:default, skip_working: true)
    assert_equal 1, HireFire::Macro::Resque.job_queue_size(:mailer, skip_working: true)
    assert_equal 0, HireFire::Macro::Resque.job_queue_size(:other, skip_working: true)
    assert_equal 3, HireFire::Macro::Resque.job_queue_size(:default, :mailer, skip_working: true)
  end

  def test_job_queue_size_ignores_workers_without_a_job
    Resque.redis.sadd(:workers, "idle-worker")

    assert_equal 0, HireFire::Macro::Resque.job_queue_size
    assert_equal 0, HireFire::Macro::Resque.job_queue_size(:default)
  end

  def test_job_queue_size_skips_corrupt_worker_payloads_for_named_queues
    enqueue_to_working_with_queue :default, BasicJob
    Resque.redis.pipelined do |pipeline|
      pipeline.set("worker:corrupt", "not-json")
      pipeline.sadd(:workers, "corrupt")
      pipeline.set("worker:null", "null")
      pipeline.sadd(:workers, "null")
    end

    assert_equal 1, HireFire::Macro::Resque.job_queue_size(:default)
    assert_equal 3, HireFire::Macro::Resque.job_queue_size
  end

  def test_job_queue_size_pages_worker_payloads_across_the_batch_boundary
    Resque.redis.pipelined do |pipeline|
      1_001.times do |i|
        queue = (i % 3 == 0) ? "mailer" : "default"
        pipeline.set("worker:#{i}", Resque.encode("queue" => queue, "payload" => {"class" => "BasicJob", "args" => []}))
        pipeline.sadd(:workers, i)
      end
    end

    assert_equal 1_001, HireFire::Macro::Resque.job_queue_size
    assert_equal 667, HireFire::Macro::Resque.job_queue_size(:default)
    assert_equal 334, HireFire::Macro::Resque.job_queue_size(:mailer)
  end

  def test_worker_walk_raises_instead_of_undercounting_when_budget_is_exceeded
    20.times { enqueue_to_working_with_queue :default, BasicJob }

    stub_resque_const(:WALK_JOB_BUDGET, 5) do
      error = assert_raises(HireFire::Errors::SampleIncomplete) do
        HireFire::Macro::Resque.job_queue_size(:default)
      end
      assert_includes error.message, "worker walk"

      assert_raises(HireFire::Errors::SampleIncomplete) do
        HireFire::Macro::Resque.job_queue_size
      end
      assert_equal 0, HireFire::Macro::Resque.job_queue_size(:default, skip_working: true)
    end
  end

  def test_plan_execute_resque_jqs_counts_working_jobs_and_samples_no_wrk
    HireFire.configure { |c| c.logger = Logger.new(File::NULL) }
    buffer = HireFire.configuration.buffer
    buffer.flush
    Resque.enqueue_to(:default, BasicJob)
    enqueue_to_working_with_queue :default, BasicJob

    HireFire::Plan.execute(
      "name" => "worker",
      "adapter" => "resque",
      "strategy" => "jqs",
      "queues" => ["default"],
      "options" => {}
    )

    flushed = buffer.flush
    assert_equal 2, flushed.dig("worker", "jqs")&.values&.last
    assert_equal 1, HireFire::Macro::Resque.job_queue_working(:default)
    assert_nil flushed.dig("worker", "wrk")
  end

  def test_plan_execute_skip_working_true_leaves_working_jobs_out_and_records_wrk
    HireFire.configure { |c| c.logger = Logger.new(File::NULL) }
    buffer = HireFire.configuration.buffer
    buffer.flush
    Resque.enqueue_to(:default, BasicJob)
    enqueue_to_working_with_queue :default, BasicJob

    HireFire::Plan.execute(
      "name" => "worker",
      "adapter" => "resque",
      "strategy" => "jqs",
      "queues" => ["default"],
      "options" => {"skip_working" => true}
    )

    flushed = buffer.flush
    assert_equal 1, flushed.dig("worker", "jqs")&.values&.last
    assert_equal 1, flushed.dig("worker", "wrk")&.values&.last
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
    assert_equal 1, HireFire::Macro::Resque.job_queue_size(:default)
  end

  def test_deprecated_queue_returns_what_job_queue_size_returns_for_each_call_shape
    Resque.enqueue_to(:default, BasicJob)
    Resque.enqueue_to(:mailer, BasicJob)
    Resque.enqueue_in_with_queue(:default, -60, BasicJob)
    Resque.enqueue_in_with_queue(:mailer, 300, BasicJob)
    enqueue_to_working_with_queue :default, BasicJob
    enqueue_to_working_with_queue :never_registered, BasicJob
    macro = HireFire::Macro::Resque

    assert_equal 5, macro.queue
    assert_equal macro.job_queue_size, macro.queue
    assert_equal 3, macro.queue(:default)
    assert_equal macro.job_queue_size(:default), macro.queue(:default)
    assert_equal macro.job_queue_size(:mailer), macro.queue("mailer")
    assert_equal macro.job_queue_size(:default, :mailer), macro.queue(:default, :mailer)
    assert_equal macro.job_queue_size(:default, :mailer), macro.queue([:default, ["mailer"]])
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

  def heartbeat(worker, seconds_ago)
    Resque.redis.hset("workers:heartbeat", worker, (Resque.data_store.server_time - seconds_ago).iso8601)
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
