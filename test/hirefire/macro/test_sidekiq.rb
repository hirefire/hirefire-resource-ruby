# frozen_string_literal: true

require "test_helper"
require "securerandom"

ENV["REDIS_URL"] ||= "redis://localhost:#{ENV.fetch("REDIS_PORT", 6379)}/0"

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
    latency = HireFire::Macro::Sidekiq.job_queue_latency
    assert_kind_of Float, latency
    assert_in_delta 0, latency, LATENCY_DELTA
  end

  def test_job_queue_latency_with_only_future_jobs
    enqueue_scheduled_future
    enqueue_retry_future
    assert_equal 0.0, HireFire::Macro::Sidekiq.job_queue_latency
  end

  def test_job_queue_latency_with_jobs
    Timecop.freeze(Time.now - 100) { enqueue }
    Timecop.freeze(Time.now - 200) { enqueue queue: "critical" }
    assert_in_delta 200, HireFire::Macro::Sidekiq.job_queue_latency, LATENCY_DELTA
    assert_in_delta 100, HireFire::Macro::Sidekiq.job_queue_latency(:default), LATENCY_DELTA
    assert_in_delta 200, HireFire::Macro::Sidekiq.job_queue_latency(:default, :critical), LATENCY_DELTA
  end

  def test_job_queue_latency_native_enqueued_at_matches_sidekiq
    Timecop.freeze(Time.now - 180) { enqueue }

    payload = oldest_queue_payload("default")
    assert payload, "expected an enqueued job payload"

    if sidekiq_8?
      assert_kind_of Integer, payload["enqueued_at"],
        "Sidekiq #{Sidekiq::VERSION} should store enqueued_at as Integer ms"
    else
      assert_kind_of Float, payload["enqueued_at"],
        "Sidekiq #{Sidekiq::VERSION} should store enqueued_at as Float seconds"
    end

    hirefire = enqueued_only_latency(:default)
    sidekiq = Sidekiq::Queue.new("default").latency

    assert_in_delta 180, hirefire, LATENCY_DELTA
    assert_in_delta 180, sidekiq, LATENCY_DELTA
    assert_in_delta sidekiq, hirefire, LATENCY_DELTA
  end

  def test_job_queue_latency_with_float_second_enqueued_at
    plant_queue_job("default", enqueued_at: Time.now.to_f - 240)

    payload = oldest_queue_payload("default")
    assert_kind_of Float, payload["enqueued_at"]

    hirefire = enqueued_only_latency(:default)
    assert_in_delta 240, hirefire, LATENCY_DELTA

    assert_in_delta Sidekiq::Queue.new("default").latency, hirefire, LATENCY_DELTA
  end

  def test_job_queue_latency_with_integer_millisecond_enqueued_at
    plant_queue_job("default", enqueued_at: ((Time.now.to_f - 300) * 1000).round)

    payload = oldest_queue_payload("default")
    assert_kind_of Integer, payload["enqueued_at"]

    hirefire = enqueued_only_latency(:default)
    assert_in_delta 300, hirefire, LATENCY_DELTA

    if sidekiq_8?
      assert_in_delta Sidekiq::Queue.new("default").latency, hirefire, LATENCY_DELTA
    end
  end

  def test_job_queue_latency_without_timestamps_is_zero
    plant_queue_job("default", enqueued_at: nil, created_at: nil)

    assert_in_delta 0.0, HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_retries: true, skip_scheduled: true), 0.001
  end

  def test_job_queue_latency_falls_back_to_created_at
    plant_queue_job("default", enqueued_at: nil, created_at: Time.now.to_f - 90)

    hirefire = enqueued_only_latency(:default)
    assert_in_delta 90, hirefire, LATENCY_DELTA
  end

  def test_job_queue_latency_with_retry_jobs
    Timecop.freeze(Time.now + 150) { enqueue_retry }
    Timecop.freeze(Time.now - 450) { enqueue_retry }
    Timecop.freeze(Time.now - 300) { 50.times { enqueue_retry } }
    Timecop.freeze(Time.now - 150) { enqueue }
    assert_in_delta 450, HireFire::Macro::Sidekiq.job_queue_latency, LATENCY_DELTA
    assert_in_delta 450, HireFire::Macro::Sidekiq.job_queue_latency(:default), LATENCY_DELTA
  end

  def test_job_queue_latency_with_scheduled_jobs
    Timecop.freeze(Time.now + 150) { enqueue_scheduled }
    Timecop.freeze(Time.now - 450) { enqueue_scheduled }
    Timecop.freeze(Time.now - 300) { 50.times { enqueue_scheduled } }
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
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, server: true, skip_scheduled: true)
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, server: true, skip_retries: true)
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, server: true, skip_working: true)
  end

  def test_working_jobs_with_future_run_at_are_excluded_client_and_server
    enqueue_working(run_at: Time.now.to_i + 120)

    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(server: true)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(skip_working: true)
  end

  def test_working_jobs_with_past_run_at_are_counted_client_and_server
    enqueue_working(run_at: Time.now.to_i - 60)

    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(server: true)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(skip_working: true)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(server: true, skip_working: true)
  end

  def test_server_lookup_does_not_double_count_numeric_queue_names
    enqueue(queue: "1")
    enqueue(queue: "1")
    enqueue(queue: "2")
    assert_equal 3, HireFire::Macro::Sidekiq.job_queue_size(server: true)
    assert_equal 3, HireFire::Macro::Sidekiq.job_queue_size
  end

  def test_server_lookup_caps_scheduled_exactly_like_client
    10.times { enqueue_scheduled }

    assert_equal 10, HireFire::Macro::Sidekiq.job_queue_size(skip_retries: true, skip_working: true)
    assert_equal 10, HireFire::Macro::Sidekiq.job_queue_size(server: true, skip_retries: true, skip_working: true)

    assert_equal 3, HireFire::Macro::Sidekiq.job_queue_size(max_scheduled: 3, skip_retries: true, skip_working: true)
    assert_equal 3, HireFire::Macro::Sidekiq.job_queue_size(server: true, max_scheduled: 3, skip_retries: true, skip_working: true)
  end

  def test_server_lookup_max_scheduled_zero_counts_no_scheduled_like_client
    5.times { enqueue_scheduled }
    enqueue

    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(max_scheduled: 0, skip_retries: true, skip_working: true)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(server: true, max_scheduled: 0, skip_retries: true, skip_working: true)
  end

  def test_server_lookup_pages_and_caps_across_the_zrange_boundary
    total = 2_300
    at = Time.now.to_i - 100

    Sidekiq.redis do |conn|
      conn.pipelined do |pipeline|
        total.times do |i|
          payload = Sidekiq.dump_json("queue" => "default", "class" => "SampleWorker", "args" => [], "jid" => "j#{i}")
          pipeline.zadd("schedule", at, payload)
        end
      end
    end

    options = {skip_retries: true, skip_working: true}
    assert_equal total, HireFire::Macro::Sidekiq.job_queue_size(server: true, **options)
    assert_equal total, HireFire::Macro::Sidekiq.job_queue_size(**options)
    assert_equal 1_500, HireFire::Macro::Sidekiq.job_queue_size(server: true, max_scheduled: 1_500, **options)
    assert_equal 1_500, HireFire::Macro::Sidekiq.job_queue_size(max_scheduled: 1_500, **options)
  end

  def test_server_lookup_negative_max_scheduled_counts_none_like_client
    5.times { enqueue_scheduled }
    enqueue

    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(max_scheduled: -5, skip_retries: true, skip_working: true)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(server: true, max_scheduled: -5, skip_retries: true, skip_working: true)
  end

  def test_server_lookup_still_counts_retries_after_zero_means_none
    enqueue_retry
    enqueue_retry

    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(server: true, skip_scheduled: true, skip_working: true)
  end

  def test_server_lookup_reraises_non_noscript_script_errors
    Sidekiq.redis do |connection|
      case identify_redis_client(connection)
      when :redis
        connection.zadd("schedule", Time.now.to_i - 100, "not-json")
      when :redis_client
        connection.call("zadd", "schedule", Time.now.to_i - 100, "not-json")
      end
    end

    error = assert_raises(StandardError) do
      HireFire::Macro::Sidekiq.job_queue_size(server: true)
    end

    refute_includes error.message, "NOSCRIPT"
  end

  def test_count_with_redis_loads_script_and_retries_on_noscript
    # Sidekiq 7/8 default to RedisClient; still exercise the redis-rb rescue path.
    introduced_redis = false
    unless defined?(::Redis::CommandError)
      Object.const_set(:Redis, Module.new) unless defined?(::Redis)
      Redis.const_set(:CommandError, Class.new(StandardError)) unless defined?(::Redis::CommandError)
      introduced_redis = true
    end

    sha = HireFire::Macro::Sidekiq::JobQueueSize::SERVER_SIDE_SCRIPT_SHA
    script = HireFire::Macro::Sidekiq::JobQueueSize::SERVER_SIDE_SCRIPT
    argv = [1_700_000_000, -1, 0, 0, 0, "default"]

    connection = mock("redis")
    seq = sequence("noscript-redis")
    connection.expects(:evalsha)
      .with(sha, argv: argv)
      .in_sequence(seq)
      .raises(::Redis::CommandError.new("NOSCRIPT No matching script. Please use EVAL."))
    connection.expects(:script)
      .with(:load, script)
      .in_sequence(seq)
      .returns("loaded-sha")
    connection.expects(:evalsha)
      .with(sha, argv: argv)
      .in_sequence(seq)
      .returns(7)

    result = HireFire::Macro::Sidekiq::JobQueueSize.send(:count_with_redis, connection, *argv)
    assert_equal 7, result
  ensure
    if introduced_redis && defined?(::Redis) && !::Redis.is_a?(Class)
      Object.send(:remove_const, :Redis)
    end
  end

  def test_count_with_redis_client_loads_script_and_retries_on_noscript
    skip "RedisClient not loaded" unless defined?(::RedisClient::CommandError)

    sha = HireFire::Macro::Sidekiq::JobQueueSize::SERVER_SIDE_SCRIPT_SHA
    script = HireFire::Macro::Sidekiq::JobQueueSize::SERVER_SIDE_SCRIPT
    argv = [1_700_000_000, -1, 0, 0, 0, "default"]
    evalsha_args = ["evalsha", sha, 0, *argv]

    connection = mock("redis_client")
    seq = sequence("noscript-redis-client")
    noscript = ::RedisClient::CommandError.new("NOSCRIPT No matching script. Please use EVAL.")
    connection.expects(:call).with(*evalsha_args).in_sequence(seq).raises(noscript)
    connection.expects(:call)
      .with("script", "load", script)
      .in_sequence(seq)
      .returns("loaded-sha")
    connection.expects(:call).with(*evalsha_args).in_sequence(seq).returns(11)

    result = HireFire::Macro::Sidekiq::JobQueueSize.send(:count_with_redis_client, connection, *argv)
    assert_equal 11, result
  end

  def test_server_lookup_recovers_from_flushed_scripts_end_to_end
    populate_queue

    Sidekiq.redis do |connection|
      case identify_redis_client(connection)
      when :redis
        connection.script(:flush)
      when :redis_client
        connection.call("script", "flush")
      end
    end

    assert_equal 6, HireFire::Macro::Sidekiq.job_queue_size(server: true)
  end

  def test_job_queue_latency_skips_older_past_due_foreign_queue_while_scanning
    Timecop.freeze(Time.now - 400) { enqueue_scheduled(queue: "mailer") }
    Timecop.freeze(Time.now - 100) { enqueue_scheduled(queue: "default") }

    assert_in_delta 100, HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_retries: true), LATENCY_DELTA
    assert_in_delta 400, HireFire::Macro::Sidekiq.job_queue_latency(:mailer, skip_retries: true), LATENCY_DELTA
    assert_in_delta 400, HireFire::Macro::Sidekiq.job_queue_latency(:default, :mailer, skip_retries: true), LATENCY_DELTA
  end

  def test_job_queue_latency_skips_older_past_due_foreign_retry_while_scanning
    Timecop.freeze(Time.now - 500) { enqueue_retry(queue: "mailer") }
    Timecop.freeze(Time.now - 120) { enqueue_retry(queue: "default") }

    assert_in_delta 120, HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_scheduled: true), LATENCY_DELTA
    assert_in_delta 500, HireFire::Macro::Sidekiq.job_queue_latency(:mailer, skip_scheduled: true), LATENCY_DELTA
  end

  def test_job_queue_size_skips_older_past_due_foreign_queue_while_scanning
    Timecop.freeze(Time.now - 400) { enqueue_scheduled(queue: "mailer") }
    Timecop.freeze(Time.now - 100) { enqueue_scheduled(queue: "default") }

    options = {skip_retries: true, skip_working: true}
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, **options)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true, **options)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:mailer, **options)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:mailer, server: true, **options)
    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(**options)
    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(server: true, **options)
  end

  def test_job_queue_size_skips_older_past_due_foreign_retry_while_scanning
    Timecop.freeze(Time.now - 500) { enqueue_retry(queue: "mailer") }
    Timecop.freeze(Time.now - 120) { enqueue_retry(queue: "default") }

    options = {skip_scheduled: true, skip_working: true}
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, **options)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true, **options)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:mailer, **options)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:mailer, server: true, **options)
    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(**options)
    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(server: true, **options)
  end

  def test_server_lookup_raises_on_unsupported_connection_type
    ::Sidekiq.stubs(:redis).yields(Object.new)

    error = assert_raises(RuntimeError) do
      HireFire::Macro::Sidekiq.job_queue_size(server: true)
    end

    assert_includes error.message, "Unsupported Redis connection type"
  end

  def test_deprecated_queue_method
    populate_queue

    assert_equal 4, HireFire::Macro::Sidekiq.queue(:default)
    assert_equal 5, HireFire::Macro::Sidekiq.queue(:default, :critical)
    assert_equal 4, HireFire::Macro::Sidekiq.queue(:default, :critical, skip_scheduled: true)
    assert_equal 4, HireFire::Macro::Sidekiq.queue(:default, :critical, skip_retries: true)
    assert_equal 4, HireFire::Macro::Sidekiq.queue(:default, :critical, skip_working: true)
  end

  def test_deprecated_queue_method_without_queues_uses_fast_lookup
    enqueue
    enqueue queue: "critical"
    enqueue_scheduled
    enqueue_scheduled_future
    enqueue_retry
    enqueue_retry_future

    assert_equal 4, HireFire::Macro::Sidekiq.queue
    assert_equal 3, HireFire::Macro::Sidekiq.queue(skip_scheduled: true)
    assert_equal 3, HireFire::Macro::Sidekiq.queue(skip_retries: true)
    assert_equal 4, HireFire::Macro::Sidekiq.queue(skip_working: true)
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

  def enqueued_only_latency(*queues)
    HireFire::Macro::Sidekiq.job_queue_latency(
      *queues,
      skip_retries: true,
      skip_scheduled: true
    )
  end

  def sidekiq_8?
    Gem::Version.new(Sidekiq::VERSION) >= Gem::Version.new("8.0.0")
  end

  def oldest_queue_payload(queue)
    raw = Sidekiq.redis { |conn| conn.lindex("queue:#{queue}", -1) }
    raw ? Sidekiq.load_json(raw) : nil
  end

  def plant_queue_job(queue, enqueued_at:, created_at: nil)
    payload = {
      "queue" => queue,
      "class" => "SampleWorker",
      "args" => [],
      "jid" => SecureRandom.hex(12)
    }
    payload["enqueued_at"] = enqueued_at unless enqueued_at.nil?
    payload["created_at"] = created_at unless created_at.nil?

    Sidekiq.redis do |connection|
      case identify_redis_client(connection)
      when :redis
        connection.sadd?("queues", queue)
        connection.lpush("queue:#{queue}", Sidekiq.dump_json(payload))
      when :redis_client
        connection.call("sadd", "queues", queue)
        connection.call("lpush", "queue:#{queue}", Sidekiq.dump_json(payload))
      end
    end
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

    sidekiq_queue = Sidekiq::Queue.new(queue)
    job = sidekiq_queue.find_job(jid)

    assert job, "Job not found in queue #{queue.inspect}"

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
    enqueue_retry(queue: queue, at: Time.now.to_i + 60)
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
