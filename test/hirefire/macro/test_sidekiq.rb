# frozen_string_literal: true

ENV["REDIS_URL"] ||= "redis://localhost:6379/15"

require "test_helper"
require "sidekiq/api"

class HireFire::Macro::SidekiqTest < Minitest::Test
  LATENCY_DELTA = 2

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

  def test_job_queue_latency_without_jobs
    assert_in_delta 0, HireFire::Macro::Sidekiq.job_queue_latency, LATENCY_DELTA
  end

  def test_job_queue_latency_with_jobs
    Timecop.freeze(Time.now - 100) { enqueue }
    Timecop.freeze(Time.now - 200) { enqueue queue: "critical" }
    assert_in_delta 200, HireFire::Macro::Sidekiq.job_queue_latency, LATENCY_DELTA
    assert_in_delta 100, HireFire::Macro::Sidekiq.job_queue_latency(:default), LATENCY_DELTA
    assert_in_delta 200, HireFire::Macro::Sidekiq.job_queue_latency(:default, :critical), LATENCY_DELTA
  end

  def test_job_queue_latency_with_retry_jobs
    Timecop.freeze(Time.now + 150) { enqueue_retry }
    Timecop.freeze(Time.now - 450) { enqueue_retry }
    Timecop.freeze(Time.now - 300) { 50.times { enqueue_retry } } # test pagination
    Timecop.freeze(Time.now - 150) { enqueue }
    assert_in_delta 450, HireFire::Macro::Sidekiq.job_queue_latency, LATENCY_DELTA
    assert_in_delta 450, HireFire::Macro::Sidekiq.job_queue_latency(:default), LATENCY_DELTA
  end

  def test_job_queue_latency_with_scheduled_jobs
    Timecop.freeze(Time.now + 150) { enqueue_scheduled }
    Timecop.freeze(Time.now - 450) { enqueue_scheduled }
    Timecop.freeze(Time.now - 300) { 50.times { enqueue_scheduled } } # test pagination
    Timecop.freeze(Time.now - 150) { enqueue }
    assert_in_delta 450, HireFire::Macro::Sidekiq.job_queue_latency, LATENCY_DELTA
    assert_in_delta 450, HireFire::Macro::Sidekiq.job_queue_latency(:default), LATENCY_DELTA
  end

  def test_job_queue_latency_with_skip_retries
    Timecop.freeze(Time.now - 250) { enqueue_retry }
    Timecop.freeze(Time.now - 150) { enqueue }
    assert_in_delta 150, HireFire::Macro::Sidekiq.job_queue_latency(skip_retries: true), LATENCY_DELTA
    assert_in_delta 150, HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_retries: true), LATENCY_DELTA
  end

  def test_job_queue_latency_with_skip_scheduled
    Timecop.freeze(Time.now - 300) { enqueue_scheduled }
    Timecop.freeze(Time.now - 150) { enqueue }
    assert_in_delta 150, HireFire::Macro::Sidekiq.job_queue_latency(skip_scheduled: true), LATENCY_DELTA
    assert_in_delta 150, HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_scheduled: true), LATENCY_DELTA
  end

  def test_deprecated_latency_method
    Timecop.freeze(Time.now - 200) { enqueue }
    Timecop.freeze(Time.now - 100) { enqueue queue: "critical" }
    assert_in_delta 200, HireFire::Macro::Sidekiq.latency(:default), LATENCY_DELTA
    assert_in_delta 100, HireFire::Macro::Sidekiq.latency(:critical), LATENCY_DELTA
  end

  def test_job_queue_size_without_jobs
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, :low)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_scheduled: true)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_working: true)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true)
  end

  def test_job_queue_size_with_jobs_using_client_lookup
    populate_queue

    assert_equal 6, HireFire::Macro::Sidekiq.job_queue_size
    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(skip_scheduled: true)
    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(skip_retries: true)
    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(skip_working: true)
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default)
    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical)
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, skip_scheduled: true)
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, skip_retries: true)
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, skip_working: true)
  end

  def test_job_queue_size_with_jobs_using_server_lookup
    populate_queue

    assert_equal 6, HireFire::Macro::Sidekiq.job_queue_size(server: true)
    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(server: true, skip_scheduled: true)
    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(server: true, skip_retries: true)
    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(server: true, skip_working: true)
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true)
    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, server: true)
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, server: true, skip_scheduled: true) # 2
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, server: true, skip_retries: true) # 2
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, server: true, skip_working: true) # 2
  end

  def test_deprecated_queue_method
    populate_queue

    assert_equal 4, HireFire::Macro::Sidekiq.queue(:default)
    assert_equal 5, HireFire::Macro::Sidekiq.queue(:default, :critical)
    assert_equal 4, HireFire::Macro::Sidekiq.queue(:default, :critical, skip_scheduled: true)
    assert_equal 4, HireFire::Macro::Sidekiq.queue(:default, :critical, skip_retries: true)
    assert_equal 4, HireFire::Macro::Sidekiq.queue(:default, :critical, skip_working: true)
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

  def enqueue(queue: "default")
    Sidekiq::Client.push(
      "queue" => queue,
      "class" => SampleWorker,
      "args" => []
    )
  end

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

    payload["failed_at"] = if Gem::Version.new(::Sidekiq::VERSION) >= Gem::Version.new("8.0.0")
      Time.now.to_i * 1000
    else
      Time.now.to_i
    end

    job.delete

    Sidekiq.redis do |connection|
      connection.zadd("retry", at, Sidekiq.dump_json(payload))
    end
  end

  def enqueue_retry_future(queue: "default")
    enqueue_retry(queue: "default", at: Time.now.to_i + 60)
  end

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
