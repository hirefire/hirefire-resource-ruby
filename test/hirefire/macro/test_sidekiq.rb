# frozen_string_literal: true

ENV["REDIS_URL"] ||= "redis://localhost:6379/12"

require "test_helper"
require "sidekiq/api"

class HireFire::Macro::SidekiqTest < Minitest::Test
  LATENCY_DELTA = 10

  def setup
    Sidekiq.redis do |connection|
      case identify_redis_client(connection)
      when :redis
        connection.flushdb
        connection.script(:flush)
      when :redis_client
        connection.call("flushdb")
        connection.call("script", "flush")
      end
    end
  end

  def test_missing_queues_raises_error
    assert_raises HireFire::Errors::MissingQueueError do
      HireFire::Macro::Sidekiq.job_queue_size
    end
  end

  def test_job_queue_size_without_jobs
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, :low)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_scheduled: true)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_working: true)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true)
  end

  def test_job_queue_size_with_jobs_using_client_lookup
    populate_queue

    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default)
    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical)
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, skip_scheduled: true)
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, skip_retries: true)
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, skip_working: true)
  end

  def test_job_queue_size_with_jobs_using_server_lookup
    populate_queue

    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true)
    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, server: true)
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, server: true, skip_scheduled: true)
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, server: true, skip_retries: true)
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, server: true, skip_working: true)
  end

  def test_latency_without_jobs
    assert_in_delta 0, HireFire::Macro::Sidekiq.job_queue_latency(:default), LATENCY_DELTA
  end

  def test_latency_with_jobs
    Timecop.freeze(Time.now - 200) { enqueue }
    Timecop.freeze(Time.now - 100) { enqueue queue: "critical" }
    assert_in_delta 200, HireFire::Macro::Sidekiq.job_queue_latency(:default), LATENCY_DELTA
    assert_in_delta 100, HireFire::Macro::Sidekiq.job_queue_latency(:critical), LATENCY_DELTA
    assert_in_delta 200, HireFire::Macro::Sidekiq.job_queue_latency(:default, :critical), LATENCY_DELTA
  end

  def test_latency_with_retry_jobs
    Timecop.freeze(Time.now + 150) { enqueue_retry }
    Timecop.freeze(Time.now - 450) { enqueue_retry }
    Timecop.freeze(Time.now - 300) { 50.times { enqueue_retry } } # test pagination
    Timecop.freeze(Time.now - 150) { enqueue }
    assert_in_delta 450, HireFire::Macro::Sidekiq.job_queue_latency(:default), LATENCY_DELTA
  end

  def test_latency_with_scheduled_jobs
    Timecop.freeze(Time.now + 150) { enqueue_scheduled }
    Timecop.freeze(Time.now - 450) { enqueue_scheduled }
    Timecop.freeze(Time.now - 300) { 50.times { enqueue_scheduled } } # test pagination
    Timecop.freeze(Time.now - 150) { enqueue }
    assert_in_delta 450, HireFire::Macro::Sidekiq.job_queue_latency(:default), LATENCY_DELTA
  end

  def test_latency_with_skip_retries
    Timecop.freeze(Time.now - 250) { enqueue_retry }
    Timecop.freeze(Time.now - 150) { enqueue }
    assert_in_delta 150, HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_retries: true), LATENCY_DELTA
  end

  def test_latency_with_skip_scheduled
    Timecop.freeze(Time.now - 300) { enqueue_scheduled }
    Timecop.freeze(Time.now - 150) { enqueue }
    assert_in_delta 150, HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_scheduled: true), LATENCY_DELTA
  end

  private

  class SampleWorker
    include Sidekiq::Worker

    def perform
    end
  end

  def populate_queue
    enqueue
    enqueue queue: "critical"
    enqueue queue: "low"
    enqueue_scheduled
    enqueue_scheduled_future
    enqueue_retry
    enqueue_retry_future
    enqueue_working
  end

  # Enqueues a `SampleWorker` job to be processed immediately. This
  # helper method interacts with Sidekiq to insert a new job into the
  # provided queue. The job will be processed as soon as a worker is
  # available and there are no higher-priority jobs in the queue.
  #
  # @param queue [String] the name of the queue to which the job should be enqueued.
  #
  def enqueue(queue: "default")
    Sidekiq::Client.push(
      "queue" => queue,
      "class" => SampleWorker,
      "args" => []
    )
  end

  # Enqueues a job to be processed at a specific time in the future. This helper method
  # interacts with Sidekiq to schedule a `SampleWorker` job using the provided queue and
  # scheduled time. Sidekiq internally uses the "at" parameter to determine when the job
  # should be moved from the scheduled set to the appropriate queue for processing.
  #
  # @param queue [String] the name of the queue to which the job should be scheduled.
  # @param at [Integer] the unix timestamp when the job should be processed.
  #
  def enqueue_scheduled(queue: "default", at: Time.now.to_i)
    Sidekiq::Client.push(
      "queue" => queue,
      "class" => SampleWorker,
      "args" => [],
      "at" => at
    )
  end

  def enqueue_scheduled_future(queue: "default")
    enqueue_scheduled(queue: queue, at: Time.now.to_i + 60)
  end

  # This helper method sets up a job in Sidekiq's retry set,
  # simulating a job that has failed and needs to be retried.  It
  # works as of Sidekiq versions 6 and 7. However, since this method
  # interacts with Sidekiq at a low level, using Redis directly, it
  # might break in future major Sidekiq updates. Therefore, it's
  # recommended to test this method against any new major releases of
  # Sidekiq.
  #
  # By default, the job is made immediately eligible for retry. If you
  # want to simulate a delay before the job becomes eligible for
  # retry, you can use the `retry_in` parameter.
  #
  # @param queue [String] the queue name to which the job should be pushed.
  # @param retry_in [Integer] (Optional) The number of seconds to delay before the job becomes eligible for retry.
  def enqueue_retry(queue: "default", at: Time.now.to_i)
    jid = Sidekiq::Client.push(
      "queue" => queue,
      "class" => SampleWorker,
      "args" => []
    )

    queue = Sidekiq::Queue.new
    job = queue.find_job(jid)

    assert job, "Job not found in queue"

    payload = job.item
    payload["failed_at"] = Time.now.utc

    job.delete

    Sidekiq.redis do |connection|
      connection.zadd("retry", at, Sidekiq.dump_json(payload))
    end
  end

  def enqueue_retry_future(queue: "default")
    enqueue_retry(queue: "default", at: Time.now.to_i + 60)
  end

  # This helper method sets up a job in Sidekiq's working set,
  # simulating a job that is currently being processed.  It interacts
  # with Sidekiq at a low level, using Redis directly, to mimic a job
  # being in progress.  As with other methods that deal with low level
  # Redis operations, it might break with future major Sidekiq
  # updates.  Thus, it's recommended to test this method against any
  # new major releases of Sidekiq.
  #
  # @param queue [String] the queue name to which the job should be pushed.
  # @param run_at [Integer] the unix timestamp when the job started processing.
  #
  def enqueue_working(queue: "default", run_at: Time.now.to_i - 60)
    Sidekiq.redis do |connection|
      process_key = "process:mock"
      worker_key = "#{process_key}:work"
      worker_data = {"queue" => queue, "run_at" => run_at}

      case identify_redis_client(connection)
      when :redis
        connection.sadd?("processes", process_key)
        connection.hset(worker_key, "jid", worker_data.to_json)
      when :redis_client
        connection.call("sadd", "processes", process_key)
        connection.call("hset", worker_key, "jid", worker_data.to_json)
      end
    end
  end

  # Identifies the type of Redis client being used with Sidekiq.
  #
  # @note Sidekiq <= 6 uses :redis (redis gem)
  # @note Sidekiq >= 7 uses :redis_client (redis_client gem)
  # @param connection [Object] the active Redis connection.
  # @return [Symbol] :redis or :redis_client
  # @raise [RuntimeError] if the Redis client type cannot be identified.
  #
  def identify_redis_client(connection)
    if defined?(::Sidekiq::RedisClientAdapter::CompatClient) && connection.is_a?(::Sidekiq::RedisClientAdapter::CompatClient)
      :redis_client
    elsif defined?(::Redis) && connection.is_a?(::Redis)
      :redis
    else
      raise "Unknown Redis Client: #{connection.inspect}"
    end
  end
end
