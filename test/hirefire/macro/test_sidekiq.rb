# frozen_string_literal: true

require "test_helper"
require "securerandom"

ENV["REDIS_URL"] ||= "redis://127.0.0.1:#{ENV.fetch("REDIS_PORT", 6379)}/0"

require "sidekiq/api"

class HireFire::Macro::SidekiqTest < Minitest::Test
  LATENCY_DELTA = 2

  def setup
    super
    refute HireFire::Macro::Sidekiq::DueCache.sample_active?,
      "product suite must never inherit an open sample wave"
    HireFire::Macro::Sidekiq::DueCache.clear_all
    flush_sidekiq_redis
  end

  def teardown
    HireFire::Macro::Sidekiq::DueCache.clear_all
    super
  end

  def test_library_loaded_is_true_when_sidekiq_gem_is_loaded
    assert HireFire::Plan.library_loaded?("sidekiq")
    assert HireFire::Plan.executable?("sidekiq")
    assert HireFire::Plan.any_allowlisted_job_queue_library_loaded?
  end

  def flush_sidekiq_redis
    Sidekiq.redis do |connection|
      connection.call("flushdb")
      connection.call("script", "flush")
    end
  end

  def test_job_queue_latency_without_jobs
    latency = HireFire::Macro::Sidekiq.job_queue_latency
    assert_float_seconds latency
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
    latency = HireFire::Macro::Sidekiq.job_queue_latency
    assert_float_seconds latency
    assert_in_delta 200, latency, LATENCY_DELTA
    assert_in_delta 100, HireFire::Macro::Sidekiq.job_queue_latency(:default), LATENCY_DELTA
    assert_in_delta 200, HireFire::Macro::Sidekiq.job_queue_latency(:default, :critical), LATENCY_DELTA
  end

  def test_job_queue_latency_three_pool_max_live_schedule_retry
    Timecop.freeze(Time.now - 100) { enqueue }
    Timecop.freeze(Time.now - 200) { enqueue_scheduled }
    Timecop.freeze(Time.now - 300) { enqueue_retry }

    assert_in_delta 300, HireFire::Macro::Sidekiq.job_queue_latency(:default), LATENCY_DELTA
    assert_in_delta 200, HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_retries: true), LATENCY_DELTA
    assert_in_delta 300, HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_scheduled: true), LATENCY_DELTA
    assert_in_delta 100, HireFire::Macro::Sidekiq.job_queue_latency(
      :default,
      skip_scheduled: true,
      skip_retries: true
    ), LATENCY_DELTA
  end

  def test_job_queue_size_and_latency_both_skips_with_only_due_are_zero
    Timecop.freeze(Time.now - 200) { enqueue_scheduled }
    Timecop.freeze(Time.now - 100) { enqueue_retry }

    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(skip_working: true)
    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(server: true, skip_working: true)
    assert_in_delta 200, HireFire::Macro::Sidekiq.job_queue_latency, LATENCY_DELTA

    opts = {skip_scheduled: true, skip_retries: true, skip_working: true}
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(**opts)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(server: true, **opts)
    assert_in_delta 0, HireFire::Macro::Sidekiq.job_queue_latency(skip_scheduled: true, skip_retries: true), LATENCY_DELTA
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

  def test_job_queue_latency_malformed_timestamp_is_zero_not_epoch
    plant_queue_job("default", enqueued_at: "not-a-time")

    assert_in_delta 0.0, enqueued_only_latency(:default), 0.001
  end

  def test_job_queue_latency_corrupt_live_json_skips_that_queue
    plant_queue_job("default", enqueued_at: Time.now.to_f - 180)
    plant_raw_queue_payload("broken", "not-json{")

    hirefire = enqueued_only_latency(:default, :broken)
    assert_in_delta 180, hirefire, LATENCY_DELTA
  end

  def test_job_queue_latency_non_hash_live_json_skips_that_queue
    plant_queue_job("default", enqueued_at: Time.now.to_f - 120)
    plant_raw_queue_payload("broken", "[1,2,3]")

    hirefire = enqueued_only_latency(:default, :broken)
    assert_in_delta 120, hirefire, LATENCY_DELTA
  end

  def test_job_queue_latency_future_float_is_zero
    plant_queue_job("default", enqueued_at: Time.now.to_f + 60)

    assert_in_delta 0.0, enqueued_only_latency(:default), 0.001
  end

  def test_job_queue_latency_future_integer_ms_is_zero
    plant_queue_job("default", enqueued_at: ((Time.now.to_f + 60) * 1000).round)

    assert_in_delta 0.0, enqueued_only_latency(:default), 0.001
  end

  def test_job_queue_latency_falls_back_to_integer_millisecond_created_at
    plant_queue_job("default", enqueued_at: nil, created_at: ((Time.now.to_f - 90) * 1000).round)

    payload = oldest_queue_payload("default")
    assert_nil payload["enqueued_at"]
    assert_kind_of Integer, payload["created_at"]

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

  def test_job_queue_latency_excludes_working_jobs
    enqueue_working(
      run_at: Time.now.to_i - 600,
      enqueued_at: Time.now.to_f - 900,
      created_at: Time.now.to_f - 900
    )

    assert_in_delta 0, HireFire::Macro::Sidekiq.job_queue_latency, LATENCY_DELTA
    assert_in_delta 0, HireFire::Macro::Sidekiq.job_queue_latency(:default), LATENCY_DELTA
  end

  def test_job_queue_latency_ignores_working_when_waiting_exists
    Timecop.freeze(Time.now - 100) { enqueue }
    enqueue_working(
      run_at: Time.now.to_i - 999,
      enqueued_at: Time.now.to_f - 900,
      created_at: Time.now.to_f - 900
    )

    assert_in_delta 100, HireFire::Macro::Sidekiq.job_queue_latency, LATENCY_DELTA
    assert_in_delta 100, HireFire::Macro::Sidekiq.job_queue_latency(:default), LATENCY_DELTA
  end

  def test_job_queue_latency_due_scheduled_only_no_live
    enqueue_scheduled(at: Time.now.to_i - 180)

    assert_in_delta 180, HireFire::Macro::Sidekiq.job_queue_latency, LATENCY_DELTA
    assert_in_delta 180, HireFire::Macro::Sidekiq.job_queue_latency(:default), LATENCY_DELTA
  end

  def test_job_queue_latency_due_retry_only_no_live
    enqueue_retry(at: Time.now.to_i - 210)

    assert_in_delta 210, HireFire::Macro::Sidekiq.job_queue_latency, LATENCY_DELTA
    assert_in_delta 210, HireFire::Macro::Sidekiq.job_queue_latency(:default), LATENCY_DELTA
  end

  def test_job_queue_latency_due_age_uses_score_not_body_timestamps
    score_age = 120
    score = Time.now.to_i - score_age
    fresh = Time.now.to_f

    plant_sorted_set_job(
      "schedule",
      score: score,
      enqueued_at: fresh,
      created_at: fresh
    )
    assert_in_delta score_age, HireFire::Macro::Sidekiq.job_queue_latency(skip_retries: true), LATENCY_DELTA
    assert_in_delta score_age, HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_retries: true), LATENCY_DELTA

    flush_sidekiq_redis
    plant_sorted_set_job(
      "retry",
      score: score,
      enqueued_at: fresh,
      created_at: fresh
    )
    assert_in_delta score_age, HireFire::Macro::Sidekiq.job_queue_latency(skip_scheduled: true), LATENCY_DELTA
    assert_in_delta score_age, HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_scheduled: true), LATENCY_DELTA
  end

  def test_job_queue_latency_due_age_ignores_older_body_timestamps
    score_age = 30
    score = Time.now.to_i - score_age
    old_body = Time.now.to_f - 900

    plant_sorted_set_job(
      "schedule",
      score: score,
      enqueued_at: old_body,
      created_at: old_body
    )
    assert_in_delta score_age, HireFire::Macro::Sidekiq.job_queue_latency(skip_retries: true), LATENCY_DELTA
    assert_in_delta score_age, HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_retries: true), LATENCY_DELTA

    flush_sidekiq_redis
    plant_sorted_set_job(
      "retry",
      score: score,
      enqueued_at: old_body,
      created_at: old_body
    )
    assert_in_delta score_age, HireFire::Macro::Sidekiq.job_queue_latency(skip_scheduled: true), LATENCY_DELTA
    assert_in_delta score_age, HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_scheduled: true), LATENCY_DELTA
  end

  def test_job_queue_latency_live_older_than_due_takes_max
    Timecop.freeze(Time.now - 500) { enqueue }
    enqueue_scheduled(at: Time.now.to_i - 100)

    assert_in_delta 500, HireFire::Macro::Sidekiq.job_queue_latency, LATENCY_DELTA
    assert_in_delta 500, HireFire::Macro::Sidekiq.job_queue_latency(:default), LATENCY_DELTA
  end

  def test_job_queue_latency_includes_due_when_score_equals_now
    frozen = Time.at(1_700_000_000)
    Timecop.freeze(frozen) do
      plant_sorted_set_job("schedule", score: frozen.to_i, enqueued_at: frozen.to_f, created_at: frozen.to_f)

      schedule_size_options = {skip_retries: true, skip_working: true}
      assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, **schedule_size_options)
      latency = HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_retries: true)
      assert_kind_of Float, latency
      assert_in_delta 0, latency, LATENCY_DELTA

      plant_sorted_set_job("retry", score: frozen.to_i, enqueued_at: frozen.to_f, created_at: frozen.to_f)
      retry_size_options = {skip_scheduled: true, skip_working: true}
      assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, **retry_size_options)
      retry_latency = HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_scheduled: true)
      assert_kind_of Float, retry_latency
      assert_in_delta 0, retry_latency, LATENCY_DELTA
    end
  end

  def test_deprecated_latency_method
    Timecop.freeze(Time.now - 200) { enqueue }
    Timecop.freeze(Time.now - 100) { enqueue queue: "critical" }
    assert_in_delta 200, HireFire::Macro::Sidekiq.latency, LATENCY_DELTA
    assert_in_delta 200, HireFire::Macro::Sidekiq.latency(:default), LATENCY_DELTA
    assert_in_delta 100, HireFire::Macro::Sidekiq.latency(:critical), LATENCY_DELTA
    assert_in_delta 100, HireFire::Macro::Sidekiq.latency("critical"), LATENCY_DELTA
  end

  def test_deprecated_latency_method_measures_due_scheduled_and_retry_jobs
    Timecop.freeze(Time.now - 100) { enqueue }
    enqueue_scheduled(at: Time.now.to_i - 300)
    enqueue_retry(queue: "critical", at: Time.now.to_i - 400)

    assert_in_delta 300, HireFire::Macro::Sidekiq.latency, LATENCY_DELTA
    assert_in_delta 400, HireFire::Macro::Sidekiq.latency(:critical), LATENCY_DELTA
    assert_in_delta HireFire::Macro::Sidekiq.job_queue_latency(:default), HireFire::Macro::Sidekiq.latency, LATENCY_DELTA
  end

  def test_job_queue_size_without_jobs
    size = HireFire::Macro::Sidekiq.job_queue_size
    assert_integer_count size
    assert_equal 0, size
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, :low)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_scheduled: true)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_working: true)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true)
  end

  def test_job_queue_size_with_jobs_using_client_lookup
    populate_queue

    size = HireFire::Macro::Sidekiq.job_queue_size
    assert_integer_count size
    assert_equal 6, size
    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(skip_scheduled: true)
    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(skip_retries: true)
    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(skip_working: true)
    assert_equal 6, HireFire::Macro::Sidekiq.job_queue_size(skip_working: false)
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default)
    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical)
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, skip_scheduled: true)
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, skip_retries: true)
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, skip_working: true)
    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, skip_working: false)
  end

  def test_job_queue_size_with_jobs_using_server_lookup
    populate_queue

    assert_equal 6, HireFire::Macro::Sidekiq.job_queue_size(server: true)
    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(server: true, skip_scheduled: true)
    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(server: true, skip_retries: true)
    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(server: true, skip_working: true)
    assert_equal 6, HireFire::Macro::Sidekiq.job_queue_size(server: true, skip_working: false)
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true)
    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, server: true)
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, server: true, skip_scheduled: true)
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, server: true, skip_retries: true)
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, server: true, skip_working: true)
    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, server: true, skip_working: false)
  end

  def test_working_jobs_with_future_run_at_are_excluded_for_named_queues_and_server
    enqueue_working(run_at: Time.now.to_i + 120)

    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(server: true)
  end

  def test_working_jobs_counted_by_default_and_excluded_when_skip_working_true
    enqueue_working(run_at: Time.now.to_i - 60)

    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(server: true)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(skip_working: false)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(server: true, skip_working: false)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(skip_working: true)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(server: true, skip_working: true)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_working: true)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true, skip_working: true)
  end

  def test_all_queues_running_count_is_the_busy_total_and_never_reads_the_working_map
    enqueue_working(queue: "default")
    enqueue_working(queue: "mailer")
    HireFire::Macro::Sidekiq::DueCache.expects(:working_jobs).never

    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size
    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_working
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(skip_working: true)
  end

  def test_working_named_queue_filter_when_skip_working_false
    enqueue_working(queue: "default", run_at: Time.now.to_i - 60)
    enqueue_working(queue: "mailer", run_at: Time.now.to_i - 90)

    [false, true].each do |server|
      opts = {skip_working: false, server: server}
      assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, **opts),
        "named :default must not count mailer working (server=#{server})"
      assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:mailer, **opts),
        "named :mailer must count only mailer working (server=#{server})"
      assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(**opts),
        "all-queues must count both working jobs (server=#{server})"
      assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:critical, **opts),
        "unrelated named queue must not count foreign working (server=#{server})"
    end
  end

  def test_job_queue_working_idle_is_zero
    working = HireFire::Macro::Sidekiq.job_queue_working
    assert_integer_count working
    assert_equal 0, working
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_working(:default)
  end

  def test_job_queue_working_counts_in_flight_and_filters_queues
    enqueue_working(queue: "default", run_at: Time.now.to_i - 60)
    enqueue_working(queue: "mailer", run_at: Time.now.to_i - 90)

    working = HireFire::Macro::Sidekiq.job_queue_working
    assert_integer_count working
    assert_equal 2, working
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_working(:default)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_working(:mailer)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_working(:critical)
    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_working(:default, :mailer)
  end

  def test_job_queue_working_excludes_future_run_at_for_named_queues
    enqueue_working(run_at: Time.now.to_i + 120)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_working(:default)
  end

  def test_job_queue_working_matches_the_running_part_of_the_size
    enqueue
    enqueue_working(queue: "default", run_at: Time.now.to_i - 30)

    waiting = HireFire::Macro::Sidekiq.job_queue_size(:default, skip_working: true)
    with_working = HireFire::Macro::Sidekiq.job_queue_size(:default)
    wrk = HireFire::Macro::Sidekiq.job_queue_working(:default)

    assert_equal with_working, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_working: false)
    assert_equal waiting + wrk, with_working
    assert_operator wrk, :>, 0
  end

  def test_plan_execute_sidekiq_jqs_counts_running_jobs_and_samples_no_wrk
    HireFire.configure { |c| c.logger = Logger.new(File::NULL) }
    buffer = HireFire.configuration.buffer
    buffer.flush

    enqueue_working(queue: "default", run_at: Time.now.to_i - 45)
    enqueue

    HireFire::Plan.execute(
      "name" => "worker",
      "adapter" => "sidekiq",
      "strategy" => "jqs",
      "queues" => ["default"],
      "options" => {}
    )

    flushed = buffer.flush
    assert flushed["worker"], "plan must buffer under process name"
    assert flushed["worker"]["jqs"], "plan must sample jqs"
    assert_nil flushed["worker"]["wrk"], "plan must sample no wrk when the size holds the running jobs"

    jqs_value = flushed["worker"]["jqs"].values.last
    working = HireFire::Macro::Sidekiq.job_queue_working(:default)
    assert_kind_of Numeric, jqs_value
    assert_equal HireFire::Macro::Sidekiq.job_queue_size(:default), jqs_value
    assert_operator working, :>, 0
    assert_equal jqs_value, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_working: true) + working
  end

  def test_plan_execute_sidekiq_jql_records_wrk_when_primary_timestamp_is_invalid
    HireFire.configure { |c| c.logger = Logger.new(File::NULL) }
    buffer = HireFire.configuration.buffer
    buffer.flush

    plant_queue_job("default", enqueued_at: "not-a-time")
    enqueue_working(queue: "default", run_at: Time.now.to_i - 20)

    HireFire::Plan.execute(
      "name" => "worker",
      "adapter" => "sidekiq",
      "strategy" => "jql",
      "queues" => ["default"],
      "options" => {}
    )

    flushed = buffer.flush
    assert_in_delta 0.0, flushed.dig("worker", "jql")&.values&.last.to_f, 0.001
    assert_equal 1, flushed.dig("worker", "wrk")&.values&.last
  end

  def test_plan_execute_sidekiq_jql_also_samples_wrk
    HireFire.configure { |c| c.logger = Logger.new(File::NULL) }
    buffer = HireFire.configuration.buffer
    buffer.flush

    enqueue_working(queue: "default", run_at: Time.now.to_i - 20)

    HireFire::Plan.execute(
      "name" => "worker",
      "adapter" => "sidekiq",
      "strategy" => "jql",
      "queues" => ["default"],
      "options" => {}
    )

    flushed = buffer.flush
    assert flushed.dig("worker", "jql")
    assert_equal 1, flushed.dig("worker", "wrk")&.values&.last
  end

  def test_plan_execute_sidekiq_empty_queues_samples_all_wrk
    HireFire.configure { |c| c.logger = Logger.new(File::NULL) }
    buffer = HireFire.configuration.buffer
    buffer.flush

    enqueue_working(queue: "default", run_at: Time.now.to_i - 30)
    enqueue_working(queue: "mailer", run_at: Time.now.to_i - 40)

    HireFire::Plan.execute(
      "name" => "worker",
      "adapter" => "sidekiq",
      "strategy" => "jqs",
      "queues" => [],
      "options" => {"skip_working" => true}
    )

    flushed = buffer.flush
    assert_equal 2, flushed.dig("worker", "wrk")&.values&.last
    assert_equal HireFire::Macro::Sidekiq.job_queue_working, flushed.dig("worker", "wrk")&.values&.last
  end

  def test_job_queue_size_due_scheduled_only_no_live
    enqueue_scheduled(at: Time.now.to_i - 90)

    options = {skip_retries: true, skip_working: true}
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(**options)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, **options)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(server: true, **options)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true, **options)
  end

  def test_job_queue_size_due_retry_only_no_live
    enqueue_retry(at: Time.now.to_i - 90)

    options = {skip_scheduled: true, skip_working: true}
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(**options)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, **options)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(server: true, **options)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true, **options)
  end

  def test_job_queue_size_future_only_is_zero
    enqueue_scheduled_future
    enqueue_retry_future

    options = {skip_working: true}
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(**options)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default, **options)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(server: true, **options)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true, **options)
  end

  def test_job_queue_size_includes_due_when_score_equals_now
    frozen = Time.at(1_700_000_000)
    Timecop.freeze(frozen) do
      plant_sorted_set_job("schedule", score: frozen.to_i, enqueued_at: frozen.to_f, created_at: frozen.to_f)

      schedule_options = {skip_retries: true, skip_working: true}
      assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, **schedule_options)
      assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true, **schedule_options)

      plant_sorted_set_job("retry", score: frozen.to_i, enqueued_at: frozen.to_f, created_at: frozen.to_f)

      retry_options = {skip_scheduled: true, skip_working: true}
      assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, **retry_options)
      assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true, **retry_options)

      assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_working: true)
      assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true, skip_working: true)
      assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(skip_working: true)
      assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(server: true, skip_working: true)
    end
  end

  def test_server_lookup_counts_due_score_in_the_current_fractional_second
    frozen = Time.at(1_700_000_000.8)
    Timecop.freeze(frozen) do
      plant_sorted_set_job("schedule", score: 1_700_000_000.5, enqueued_at: frozen.to_f)

      options = {skip_retries: true, skip_working: true}
      assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, **options)
      assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true, **options)
      assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(**options)
      assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(server: true, **options)
    end
  end

  def test_skip_working_nil_counts_working_like_the_default
    enqueue
    enqueue_working(run_at: Time.now.to_i - 60)

    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(skip_working: nil)
    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(server: true, skip_working: nil)
    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_working: nil)
  end

  def test_plan_execute_skip_working_false_counts_running_jobs_and_samples_no_wrk
    HireFire.configure { |c| c.logger = Logger.new(File::NULL) }
    buffer = HireFire.configuration.buffer
    buffer.flush
    enqueue
    enqueue_working(queue: "default", run_at: Time.now.to_i - 30)

    HireFire::Plan.execute(
      "name" => "worker",
      "adapter" => "sidekiq",
      "strategy" => "jqs",
      "queues" => ["default"],
      "options" => {"skip_working" => false}
    )

    flushed = buffer.flush
    assert_equal 2, flushed.dig("worker", "jqs")&.values&.last
    assert_nil flushed.dig("worker", "wrk")
  end

  def test_plan_execute_skip_working_true_leaves_running_jobs_out_and_still_records_wrk
    HireFire.configure { |c| c.logger = Logger.new(File::NULL) }
    buffer = HireFire.configuration.buffer
    buffer.flush
    enqueue
    enqueue_working(queue: "default", run_at: Time.now.to_i - 30)

    HireFire::Plan.execute(
      "name" => "worker",
      "adapter" => "sidekiq",
      "strategy" => "jqs",
      "queues" => ["default"],
      "options" => {"skip_working" => true}
    )

    flushed = buffer.flush
    assert_equal 1, flushed.dig("worker", "jqs")&.values&.last
    assert_equal 1, flushed.dig("worker", "wrk")&.values&.last
  end

  def test_server_lookup_does_not_double_count_numeric_queue_names
    enqueue(queue: "1")
    enqueue(queue: "1")
    enqueue(queue: "2")
    assert_equal 3, HireFire::Macro::Sidekiq.job_queue_size(server: true)
    assert_equal 3, HireFire::Macro::Sidekiq.job_queue_size
  end

  def test_server_lookup_caps_scheduled_exactly_like_named_client
    10.times { enqueue_scheduled }

    assert_equal 10, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    assert_equal 10, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true, skip_retries: true, skip_working: true)

    assert_equal 3, HireFire::Macro::Sidekiq.job_queue_size(:default, max_scheduled: 3, skip_retries: true, skip_working: true)
    assert_equal 3, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true, max_scheduled: 3, skip_retries: true, skip_working: true)
    assert_equal 10, HireFire::Macro::Sidekiq.job_queue_size(max_scheduled: 3, skip_retries: true, skip_working: true)
  end

  def test_max_scheduled_matching_only_skips_foreign_client_and_server
    5.times { |i| plant_sorted_set_job("schedule", queue: "foreign", score: Time.now.to_f - 100 - i, enqueued_at: Time.now.to_f) }
    3.times { |i| plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 10 - i, enqueued_at: Time.now.to_f) }

    options = {max_scheduled: 2, skip_retries: true, skip_working: true}
    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(:default, **options)
    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true, **options)

    assert_equal 3, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    assert_equal 3, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true, skip_retries: true, skip_working: true)
  end

  def test_server_lookup_max_scheduled_zero_counts_no_scheduled_like_named_client
    5.times { enqueue_scheduled }
    enqueue

    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, max_scheduled: 0, skip_retries: true, skip_working: true)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true, max_scheduled: 0, skip_retries: true, skip_working: true)
    assert_equal 6, HireFire::Macro::Sidekiq.job_queue_size(max_scheduled: 0, skip_retries: true, skip_working: true)
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
    assert_equal 1_500, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true, max_scheduled: 1_500, **options)
    assert_equal 1_500, HireFire::Macro::Sidekiq.job_queue_size(:default, max_scheduled: 1_500, **options)
    assert_equal total, HireFire::Macro::Sidekiq.job_queue_size(max_scheduled: 1_500, **options)
  end

  def test_server_lookup_negative_max_scheduled_counts_none_like_named_client
    5.times { enqueue_scheduled }
    enqueue

    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, max_scheduled: -5, skip_retries: true, skip_working: true)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true, max_scheduled: -5, skip_retries: true, skip_working: true)
    assert_equal 6, HireFire::Macro::Sidekiq.job_queue_size(max_scheduled: -5, skip_retries: true, skip_working: true)
  end

  def test_max_scheduled_zero_caps_schedule_only_retries_still_full_named_and_server
    3.times { enqueue_scheduled }
    2.times { enqueue_retry }

    zero_cap = {max_scheduled: 0, skip_working: true}
    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(:default, **zero_cap)
    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true, **zero_cap)

    positive_cap = {max_scheduled: 1, skip_working: true}
    assert_equal 3, HireFire::Macro::Sidekiq.job_queue_size(:default, **positive_cap)
    assert_equal 3, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true, **positive_cap)
  end

  def test_server_lookup_skips_corrupt_due_members
    plant_sorted_set_job("schedule", score: Time.now.to_i - 100, enqueued_at: Time.now.to_f)
    Sidekiq.redis do |connection|
      connection.call("zadd", "schedule", Time.now.to_i - 90, "not-json")
    end

    options = {skip_retries: true, skip_working: true}
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true, **options)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(server: true, **options)
  end

  def test_a_server_that_keeps_reporting_a_missing_script_is_asked_twice_and_no_more
    noscript = ::RedisClient::CommandError.new("NOSCRIPT No matching script. Please use EVAL.")
    connection = mock("connection")
    connection.expects(:call).with("evalsha", any_parameters).once.raises(noscript)
    connection.expects(:call).with("eval", any_parameters).once.raises(noscript)
    ::Sidekiq.stubs(:redis).yields(connection)

    assert_raises(::RedisClient::CommandError) do
      HireFire::Macro::Sidekiq.job_queue_size(:default, server: true)
    end
  end

  def test_a_script_error_other_than_a_missing_script_is_raised_at_once
    failure = ::RedisClient::CommandError.new("ERR Error running script")
    connection = mock("connection")
    connection.expects(:call).with("evalsha", any_parameters).once.raises(failure)
    ::Sidekiq.stubs(:redis).yields(connection)

    assert_raises(::RedisClient::CommandError) do
      HireFire::Macro::Sidekiq.job_queue_size(:default, server: true)
    end
  end

  def test_the_server_script_is_exact_up_to_its_member_budget
    seed_due_scheduled(10_000)
    options = {server: true, skip_retries: true, skip_working: true}

    assert_equal 10_000, HireFire::Macro::Sidekiq.job_queue_size(:default, **options)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:mailer, **options)
  end

  def test_the_server_script_over_its_member_budget_counts_every_member_it_did_not_read
    seed_due_scheduled(12_000)
    seed_due_scheduled(11_000, set: "retry")
    scheduled = {server: true, skip_retries: true, skip_working: true}
    retries = {server: true, skip_scheduled: true, skip_working: true}

    before = zrange_calls
    assert_equal 12_000, HireFire::Macro::Sidekiq.job_queue_size(:default, **scheduled)
    assert_equal 11, zrange_calls - before
    assert_equal 2_000, HireFire::Macro::Sidekiq.job_queue_size(:mailer, **scheduled)
    assert_equal 12_000, HireFire::Macro::Sidekiq.job_queue_size(**scheduled)
    assert_equal 500, HireFire::Macro::Sidekiq.job_queue_size(:mailer, max_scheduled: 500, **scheduled)
    assert_equal 2_000, HireFire::Macro::Sidekiq.job_queue_size(:mailer, max_scheduled: 2_000, **scheduled)
    assert_equal 1_000, HireFire::Macro::Sidekiq.job_queue_size(:mailer, **retries)
    assert_equal 11_000, HireFire::Macro::Sidekiq.job_queue_size(:default, **retries)
  end

  def test_the_server_script_does_not_hold_redis_for_long_on_a_large_due_set
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
    size = HireFire::Macro::Sidekiq.job_queue_size(:default, server: true, skip_retries: true, skip_working: true)
    running = false
    thread.join

    assert_equal 500_000, size
    assert_operator slowest, :<, 0.1
  ensure
    pinger&.close
  end

  def test_server_lookup_recovers_from_flushed_scripts_end_to_end
    populate_queue

    Sidekiq.redis do |connection|
      connection.call("script", "flush")
    end

    assert_equal 6, HireFire::Macro::Sidekiq.job_queue_size(server: true)
    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(server: true, skip_working: true)
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
    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(:default, :mailer, **options)
    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(:default, :mailer, server: true, **options)
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
    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(:default, :mailer, **options)
    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(:default, :mailer, server: true, **options)
    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(**options)
    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(server: true, **options)
  end

  def test_deprecated_queue_method
    populate_queue

    assert_equal 4, HireFire::Macro::Sidekiq.queue(:default)
    assert_equal 5, HireFire::Macro::Sidekiq.queue(:default, :critical)
    assert_equal 4, HireFire::Macro::Sidekiq.queue(:default, :critical, skip_scheduled: true)
    assert_equal 4, HireFire::Macro::Sidekiq.queue(:default, :critical, skip_retries: true)
    assert_equal 4, HireFire::Macro::Sidekiq.queue(:default, :critical, skip_working: true)
    assert_equal 5, HireFire::Macro::Sidekiq.queue(:default, :critical, skip_working: false)
    assert_equal 5, HireFire::Macro::Sidekiq.queue(:default, :critical, skip_working: nil)
  end

  def test_deprecated_queue_method_without_queues_reads_the_busy_total
    enqueue
    enqueue queue: "critical"
    enqueue_scheduled
    enqueue_scheduled_future
    enqueue_retry
    enqueue_retry_future
    enqueue_working
    HireFire::Macro::Sidekiq::DueCache.expects(:working_jobs).never

    assert_equal 5, HireFire::Macro::Sidekiq.queue
    assert_equal 4, HireFire::Macro::Sidekiq.queue(skip_scheduled: true)
    assert_equal 4, HireFire::Macro::Sidekiq.queue(skip_retries: true)
    assert_equal 4, HireFire::Macro::Sidekiq.queue(skip_working: true)
    assert_equal 5, HireFire::Macro::Sidekiq.queue(skip_working: false)
    assert_equal 5, HireFire::Macro::Sidekiq.queue(skip_working: nil)
  end

  def test_deprecated_queue_returns_what_job_queue_size_returns_for_each_call_shape
    populate_queue
    3.times { enqueue_scheduled }
    macro = HireFire::Macro::Sidekiq

    assert_equal macro.job_queue_size, macro.queue
    assert_equal macro.job_queue_size(:default), macro.queue(:default)
    assert_equal macro.job_queue_size(:default), macro.queue("default")
    assert_equal macro.job_queue_size(:default, :critical), macro.queue(:default, :critical)
    assert_equal macro.job_queue_size(:default, :critical), macro.queue([:default, ["critical"]])
    assert_equal macro.job_queue_size(:default, skip_scheduled: true), macro.queue(:default, skip_scheduled: true)
    assert_equal macro.job_queue_size(:default, skip_retries: true), macro.queue(:default, skip_retries: true)
    assert_equal macro.job_queue_size(:default, skip_working: true), macro.queue(:default, skip_working: true)
    assert_equal macro.job_queue_size(:default, max_scheduled: 2), macro.queue(:default, max_scheduled: 2)
    assert_equal macro.job_queue_size(:default, max_scheduled: 2), macro.queue([:default], {max_scheduled: 2})
    assert_equal macro.job_queue_size(skip_scheduled: true, skip_retries: true), macro.queue(skip_scheduled: true, skip_retries: true)
  end

  def test_deprecated_queue_passes_on_only_the_options_the_1_x_method_read
    options = {skip_scheduled: true, skip_retries: true, skip_working: true, max_scheduled: 5}
    HireFire::Macro::Sidekiq.expects(:job_queue_size).with(:default, "critical", **options).returns(7)

    assert_equal 7, HireFire::Macro::Sidekiq.queue(
      :default, "critical", **options, :server => true, :bogus => 1, "skip_working" => false
    )
  end

  def test_a_named_due_walk_over_its_budget_counts_every_member_it_did_not_read
    20.times { enqueue_scheduled(at: Time.now.to_i - 60) }
    3.times { enqueue_scheduled(queue: "mailer", at: Time.now.to_i - 10) }
    options = {skip_retries: true, skip_working: true}

    stub_due_cache_const(:WALK_MEMBER_BUDGET, 5) do
      assert_equal 23, HireFire::Macro::Sidekiq.job_queue_size(:default, **options)
      assert_equal 19, HireFire::Macro::Sidekiq.job_queue_size(:mailer, **options)
      assert_equal 23, HireFire::Macro::Sidekiq.job_queue_size(:default, :mailer, **options)
      assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(:mailer, max_scheduled: 2, **options)
    end
    assert_equal 20, HireFire::Macro::Sidekiq.job_queue_size(:default, **options)
    assert_equal 3, HireFire::Macro::Sidekiq.job_queue_size(:mailer, **options)
    assert_equal 23, HireFire::Macro::Sidekiq.job_queue_size(**options)
  end

  def test_a_named_latency_walk_over_its_budget_reports_the_age_of_the_first_member_it_did_not_read
    20.times { enqueue_scheduled(at: Time.now.to_i - 60) }
    enqueue_scheduled(queue: "mailer", at: Time.now.to_i - 10)

    stub_due_cache_const(:WALK_MEMBER_BUDGET, 5) do
      assert_in_delta 60, HireFire::Macro::Sidekiq.job_queue_latency(:mailer, skip_retries: true), 2
      assert_in_delta 60, HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_retries: true), 2
    end
    assert_in_delta 10, HireFire::Macro::Sidekiq.job_queue_latency(:mailer, skip_retries: true), 2
  end

  def test_a_walk_past_the_time_budget_counts_every_member_it_did_not_read
    3.times { enqueue_scheduled(at: Time.now.to_i - 60) }

    stub_due_cache_const(:WALK_TIME_BUDGET, 0) do
      assert_equal 3, HireFire::Macro::Sidekiq.job_queue_size(:mailer, skip_retries: true, skip_working: true)
    end
  end

  def test_a_walk_that_ends_on_the_last_member_inside_its_budget_is_exact
    4.times { enqueue_scheduled(at: Time.now.to_i - 60) }
    enqueue_scheduled_future

    stub_due_cache_const(:WALK_MEMBER_BUDGET, 5) do
      assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
      assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:mailer, skip_retries: true, skip_working: true)
    end
  end

  def test_a_walk_over_its_budget_is_not_repeated_for_the_other_entries_of_a_sample_round
    20.times { enqueue_scheduled(at: Time.now.to_i - 60) }
    options = {skip_retries: true, skip_working: true}

    stub_due_cache_const(:WALK_MEMBER_BUDGET, 5) do
      wave = HireFire::Macro::Sidekiq::DueCache.begin_sample!
      before = zrange_calls
      sizes = %w[default mailer other].map { |queue| HireFire::Macro::Sidekiq.job_queue_size(queue, **options) }
      latency = HireFire::Macro::Sidekiq.job_queue_latency(:mailer, skip_retries: true)
      calls = zrange_calls - before
      HireFire::Macro::Sidekiq::DueCache.end_sample!(wave)

      assert_equal [20, 16, 16], sizes
      assert_in_delta 60, latency, 2
      assert_equal 1, calls
    end
  end

  def test_a_named_size_at_the_real_walk_budget_reports_a_number_and_reads_the_set_once_per_sample_round
    seed_due_scheduled(60_000)
    options = {skip_retries: true, skip_working: true}

    wave = HireFire::Macro::Sidekiq::DueCache.begin_sample!
    before = zrange_calls
    sizes = %w[default one two three four].map { |queue| HireFire::Macro::Sidekiq.job_queue_size(queue, **options) }
    calls = zrange_calls - before
    HireFire::Macro::Sidekiq::DueCache.end_sample!(wave)

    assert_equal [60_000, 10_001, 10_001, 10_001, 10_001], sizes
    assert_equal 50, calls
  end

  def test_plan_records_the_upper_bound_when_the_named_walk_budget_is_exceeded
    20.times { enqueue_scheduled(at: Time.now.to_i - 60) }
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)
    stub_due_cache_const(:WALK_MEMBER_BUDGET, 5) do
      HireFire::Plan.execute(
        "name" => "worker",
        "adapter" => "sidekiq",
        "strategy" => "jqs",
        "queues" => ["default"],
        "options" => {"skip_retries" => true, "skip_working" => true}
      )
    end
    assert_equal [20], HireFire.configuration.buffer.flush.dig("worker", "jqs").values
    assert_empty log.string
  end

  def test_working_map_is_read_once_per_sample_wave
    enqueue
    enqueue_working(queue: "default")
    enqueue_working(queue: "mailer")
    calls = 0
    original = Sidekiq::Workers.method(:new)
    Sidekiq::Workers.define_singleton_method(:new) do |*args, **kwargs|
      calls += 1
      original.call(*args, **kwargs)
    end

    HireFire::Macro::Sidekiq.before_sample_job_queues
    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(:default)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_working(:default)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_working(:mailer)
    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_working(:default, :mailer)
    HireFire::Macro::Sidekiq.after_sample_job_queues

    assert_equal 1, calls
  ensure
    HireFire::Macro::Sidekiq.after_sample_job_queues
    Sidekiq::Workers.singleton_class.remove_method(:new)
  end

  private

  def zrange_calls
    Sidekiq.redis { |connection| connection.call("info", "commandstats") }[/cmdstat_zrange:calls=(\d+)/, 1].to_i
  end

  def seed_due_scheduled(count, queue: "default", set: "schedule")
    script = <<~LUA
      for i = 1, tonumber(ARGV[1]) do
        redis.call("zadd", ARGV[4], ARGV[2], '{"class":"SampleWorker","args":[],"queue":"' .. ARGV[3] .. '","jid":"' .. i .. '"}')
      end
    LUA
    Sidekiq.redis { |connection| connection.call("eval", script, 0, count, Time.now.to_f - 60, queue, set) }
  end

  def stub_due_cache_const(name, value)
    cache = HireFire::Macro::Sidekiq::DueCache
    original = cache.const_get(name)
    cache.send(:remove_const, name)
    cache.const_set(name, value)
    yield
  ensure
    cache.send(:remove_const, name)
    cache.const_set(name, original)
  end

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

  def plant_raw_queue_payload(queue, payload)
    Sidekiq.redis do |connection|
      connection.call("sadd", "queues", queue)
      connection.call("lpush", "queue:#{queue}", payload)
    end
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
      connection.call("sadd", "queues", queue)
      connection.call("lpush", "queue:#{queue}", Sidekiq.dump_json(payload))
    end
  end

  def plant_sorted_set_job(set_name, score:, enqueued_at:, queue: "default", created_at: nil)
    payload = {
      "queue" => queue,
      "class" => "SampleWorker",
      "args" => [],
      "jid" => SecureRandom.hex(12),
      "enqueued_at" => enqueued_at
    }
    payload["created_at"] = created_at unless created_at.nil?

    Sidekiq.redis do |connection|
      connection.call("zadd", set_name, score, Sidekiq.dump_json(payload))
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

  def enqueue_working(
    queue: "default",
    run_at: Time.now.to_i - 60,
    enqueued_at: Time.now.to_f - 900,
    created_at: Time.now.to_f - 900
  )
    Sidekiq.redis do |connection|
      process_key = "process:mock"
      worker_key = "#{process_key}:work"
      jid = SecureRandom.hex(12)
      job_payload = {
        "queue" => queue,
        "class" => "SampleWorker",
        "args" => [],
        "jid" => jid,
        "enqueued_at" => enqueued_at,
        "created_at" => created_at
      }
      worker_data = {
        "queue" => queue,
        "run_at" => run_at,
        "payload" => Sidekiq.dump_json(job_payload)
      }

      connection.call("sadd", "processes", process_key)
      connection.call("hincrby", process_key, "busy", 1)
      connection.call("hset", worker_key, jid, Sidekiq.dump_json(worker_data))
    end
  end
end
