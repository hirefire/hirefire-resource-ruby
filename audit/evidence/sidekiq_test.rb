# frozen_string_literal: true

require_relative "../../test/hirefire/macro/test_sidekiq"

class SidekiqEvidence < HireFire::Macro::SidekiqTest
  def test_evidence_max_scheduled_caps_the_count_without_queue_names
    5.times { enqueue_scheduled(queue: "default", at: Time.now.to_i - 60) }
    options = {max_scheduled: 2, skip_retries: true, skip_working: true}

    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(server: true, **options)
    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(:default, **options)
    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(**options)
  end

  def test_evidence_an_enqueued_at_in_integer_seconds_is_not_read_as_1970
    payload = JSON.generate("class" => "BasicJob", "args" => [], "queue" => "default", "jid" => "a" * 24, "enqueued_at" => Time.now.to_i - 30)
    Sidekiq.redis do |connection|
      connection.call("sadd", "queues", "default")
      connection.call("lpush", "queue:default", payload)
    end

    assert_in_delta 30, HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_retries: true, skip_scheduled: true), 5
  end

  def test_evidence_a_named_queue_size_over_the_walk_budget_still_reports_a_number
    score = Time.now.to_f - 60
    Sidekiq.redis do |connection|
      60.times do |batch|
        members = Array.new(1_000) { |index| [score, JSON.generate("class" => "BasicJob", "args" => [], "queue" => "default", "jid" => "#{batch}-#{index}")] }.flatten
        connection.call("zadd", "schedule", *members)
      end
    end

    size = HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    assert_operator size, :>=, 50_000
  end

  def test_evidence_a_budget_failure_does_not_repeat_the_walk_for_every_named_entry
    seed_due_scheduled(60_000)
    zrange_calls = -> { Sidekiq.redis { |connection| connection.call("info", "commandstats") }[/cmdstat_zrange:calls=(\d+)/, 1].to_i }
    wave = HireFire::Macro::Sidekiq::DueCache.begin_sample!
    before = zrange_calls.call
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    failures = %w[one two three four five].count do |queue|
      HireFire::Macro::Sidekiq.job_queue_size(queue, skip_retries: true, skip_working: true)
      false
    rescue HireFire::Errors::SampleIncomplete
      true
    end
    seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    calls = zrange_calls.call - before
    HireFire::Macro::Sidekiq::DueCache.end_sample!(wave)

    assert_operator calls, :<=, 50, "#{failures} of 5 named entries raised SampleIncomplete in one sample round, with #{calls} ZRANGE calls of 1,000 members each in #{seconds.round(2)} seconds"
  end

  def test_evidence_the_lua_size_does_not_block_redis
    seed_due_scheduled(500_000)
    pinger = RedisClient.new(url: ENV.fetch("REDIS_URL"))
    slowest = 0.0
    running = true
    thread = Thread.new do
      while running
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        pinger.call("PING")
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        slowest = elapsed if elapsed > slowest
        sleep(0.005)
      end
    end
    sleep(0.2)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    size = HireFire::Macro::Sidekiq.job_queue_size(:default, server: true, skip_retries: true, skip_working: true)
    seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    running = false
    thread.join

    assert_operator slowest, :<, 0.1, "the script counted #{size} due jobs in #{seconds.round(2)} seconds, and another client waited #{slowest.round(2)} seconds for a PING"
  end

  def test_evidence_a_missing_script_is_loaded_once
    connection = Object.new
    calls = Hash.new(0)
    connection.define_singleton_method(:call) do |command, *|
      calls[command] += 1
      raise "stopped by the test" if calls[command] > 1_000
      raise RedisClient::CommandError, "NOSCRIPT No matching script. Please use EVAL." if command == "evalsha"

      "sha"
    end

    error = assert_raises(RuntimeError, RedisClient::CommandError) do
      HireFire::Macro::Sidekiq::JobQueueSize.send(:count_with_redis_client, connection, 0, -1, 0, 0, 0)
    end

    assert_operator calls["evalsha"], :<=, 2, "against a server that keeps answering NOSCRIPT, EVALSHA ran #{calls["evalsha"]} times and SCRIPT LOAD #{calls["script"]} times until the test stopped the loop (#{error.message})"
  end

  private

  def seed_due_scheduled(count)
    score = Time.now.to_f - 60
    Sidekiq.redis do |connection|
      (count / 1_000).times do |batch|
        members = Array.new(1_000) { |index| [score, JSON.generate("class" => "BasicJob", "args" => [], "queue" => "default", "jid" => "#{batch}-#{index}")] }.flatten
        connection.call("zadd", "schedule", *members)
      end
    end
  end
end
