# frozen_string_literal: true

require "test_helper"
require "securerandom"

ENV["REDIS_URL"] ||= "redis://localhost:#{ENV.fetch("REDIS_PORT", 6379)}/0"

require "sidekiq/api"

class HireFire::Macro::SidekiqTest < Minitest::Test
  LATENCY_DELTA = 2

  def setup
    super
    # Before clear: prior suite must not leave sample_active true.
    refute HireFire::Macro::Sidekiq::DueCache.sample_active?,
      "product suite must never inherit an open sample wave"
    HireFire::Macro::Sidekiq::DueCache.clear_all
    HireFire::Macro::Sidekiq::DueCache.trace = false
    HireFire::Macro::Sidekiq::DueCache.clear_trace!
    flush_sidekiq_redis
  end

  def teardown
    HireFire::Macro::Sidekiq::DueCache.trace = false
    HireFire::Macro::Sidekiq::DueCache.clear_trace!
    HireFire::Macro::Sidekiq::DueCache.clear_all
    super
  end

  def flush_sidekiq_redis
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
    # Realistic WorkSet entry: nested payload with old enqueued_at/created_at so a
    # regression that folds WorkSet payload ages into JQL reports ~900, not 0.
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

  # Inverse of due_age_uses_score_not_body_timestamps: score is only slightly past due
  # while body enqueued_at/created_at are much older. Due JQL is eligibility lateness
  # (now - score), not original create/enqueue age.
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

  # score == now: eligibility age is 0 whether the job is included or excluded, so
  # latency≈0 alone does not prove the inclusive bound. JQS size==1 is the real
  # residual lock; latency is only a smoke check (Float, no raise, age 0).
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
    # populate_queue composition (waiting default 5, with working 6):
    # live: default+critical+low = 3; due schedule = 1; due retry = 1; working = 1 (excluded by default)
    # futures on schedule/retry do not count.

    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size # 3 live + 1 schedule + 1 retry
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(skip_scheduled: true) # 3 live + 1 retry
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(skip_retries: true) # 3 live + 1 schedule
    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(skip_working: true) # same as default
    assert_equal 6, HireFire::Macro::Sidekiq.job_queue_size(skip_working: false) # +1 working
    assert_equal 3, HireFire::Macro::Sidekiq.job_queue_size(:default) # 1 live + 1 schedule + 1 retry
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical) # +1 critical live
    assert_equal 3, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, skip_scheduled: true)
    assert_equal 3, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, skip_retries: true)
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, skip_working: true)
    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, skip_working: false) # +working on default
  end

  def test_job_queue_size_with_jobs_using_server_lookup
    populate_queue
    # Same composition as client_lookup (server Lua path).

    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(server: true)
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(server: true, skip_scheduled: true)
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(server: true, skip_retries: true)
    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(server: true, skip_working: true)
    assert_equal 6, HireFire::Macro::Sidekiq.job_queue_size(server: true, skip_working: false)
    assert_equal 3, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true)
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, server: true)
    assert_equal 3, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, server: true, skip_scheduled: true)
    assert_equal 3, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, server: true, skip_retries: true)
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, server: true, skip_working: true)
    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(:default, :critical, server: true, skip_working: false)
  end

  def test_working_jobs_with_future_run_at_are_excluded_client_and_server
    enqueue_working(run_at: Time.now.to_i + 120)

    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(server: true)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(skip_working: false)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(server: true, skip_working: false)
  end

  def test_working_jobs_excluded_by_default_and_counted_when_skip_working_false
    enqueue_working(run_at: Time.now.to_i - 60)

    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(server: true)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(skip_working: true)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(server: true, skip_working: true)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(skip_working: false)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(server: true, skip_working: false)
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
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_working
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_working(:default)
  end

  def test_job_queue_working_counts_in_flight_and_filters_queues
    enqueue_working(queue: "default", run_at: Time.now.to_i - 60)
    enqueue_working(queue: "mailer", run_at: Time.now.to_i - 90)

    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_working
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_working(:default)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_working(:mailer)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_working(:critical)
    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_working(:default, :mailer)
  end

  def test_job_queue_working_excludes_future_run_at
    enqueue_working(run_at: Time.now.to_i + 120)
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_working
  end

  def test_job_queue_working_matches_skip_working_false_contribution
    enqueue
    enqueue_working(queue: "default", run_at: Time.now.to_i - 30)

    waiting = HireFire::Macro::Sidekiq.job_queue_size(:default, skip_working: true)
    with_working = HireFire::Macro::Sidekiq.job_queue_size(:default, skip_working: false)
    wrk = HireFire::Macro::Sidekiq.job_queue_working(:default)

    assert_equal waiting, HireFire::Macro::Sidekiq.job_queue_size(:default)
    assert_equal waiting + wrk, with_working
    assert_operator wrk, :>, 0
  end

  def test_plan_execute_sidekiq_jqs_also_samples_wrk
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
    assert flushed["worker"]["wrk"], "plan must sample wrk companion"

    jqs_value = flushed["worker"]["jqs"].values.last
    wrk_value = flushed["worker"]["wrk"].values.last
    assert_kind_of Numeric, jqs_value
    assert_kind_of Numeric, wrk_value
    assert_equal HireFire::Macro::Sidekiq.job_queue_working(:default), wrk_value
    assert_equal HireFire::Macro::Sidekiq.job_queue_size(:default), jqs_value
    assert_operator wrk_value, :>, 0
    # Waiting-only jqs must not include working.
    assert_equal jqs_value, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_working: true)
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
      "options" => {}
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
    end
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

    # Walk budget: named client and server still cap. Client all-queues ZCOUNT does not.
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

    # Cap 2 with 5 older foreign dues: foreign must not consume the cap.
    assert_equal 3, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    assert_equal 3, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true, skip_retries: true, skip_working: true)
  end

  def test_server_lookup_max_scheduled_zero_counts_no_scheduled_like_named_client
    5.times { enqueue_scheduled }
    enqueue

    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, max_scheduled: 0, skip_retries: true, skip_working: true)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true, max_scheduled: 0, skip_retries: true, skip_working: true)
    # Client all-queues ZCOUNT ignores the walk budget.
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
    # Client all-queues still returns the full due set under max_scheduled.
    assert_equal total, HireFire::Macro::Sidekiq.job_queue_size(max_scheduled: 1_500, **options)
  end

  def test_server_lookup_negative_max_scheduled_counts_none_like_named_client
    5.times { enqueue_scheduled }
    enqueue

    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, max_scheduled: -5, skip_retries: true, skip_working: true)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, server: true, max_scheduled: -5, skip_retries: true, skip_working: true)
    assert_equal 6, HireFire::Macro::Sidekiq.job_queue_size(max_scheduled: -5, skip_retries: true, skip_working: true)
  end

  # max_scheduled is schedule-only walk budget on named/server; retries still full.
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

    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(server: true)
    assert_equal 6, HireFire::Macro::Sidekiq.job_queue_size(server: true, skip_working: false)
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

  def test_server_lookup_raises_on_unsupported_connection_type
    ::Sidekiq.stubs(:redis).yields(Object.new)

    error = assert_raises(RuntimeError) do
      HireFire::Macro::Sidekiq.job_queue_size(server: true)
    end

    assert_includes error.message, "Unsupported Redis connection type"
  end

  def test_deprecated_queue_method
    populate_queue

    assert_equal 3, HireFire::Macro::Sidekiq.queue(:default)
    assert_equal 4, HireFire::Macro::Sidekiq.queue(:default, :critical)
    assert_equal 3, HireFire::Macro::Sidekiq.queue(:default, :critical, skip_scheduled: true)
    assert_equal 3, HireFire::Macro::Sidekiq.queue(:default, :critical, skip_retries: true)
    assert_equal 4, HireFire::Macro::Sidekiq.queue(:default, :critical, skip_working: true)
    assert_equal 5, HireFire::Macro::Sidekiq.queue(:default, :critical, skip_working: false)
  end

  def test_deprecated_queue_method_without_queues_uses_fast_lookup
    enqueue
    enqueue queue: "critical"
    enqueue_scheduled
    enqueue_scheduled_future
    enqueue_retry
    enqueue_retry_future
    enqueue_working

    assert_equal 4, HireFire::Macro::Sidekiq.queue
    assert_equal 3, HireFire::Macro::Sidekiq.queue(skip_scheduled: true)
    assert_equal 3, HireFire::Macro::Sidekiq.queue(skip_retries: true)
    assert_equal 4, HireFire::Macro::Sidekiq.queue(skip_working: true)
    assert_equal 5, HireFire::Macro::Sidekiq.queue(skip_working: false)
  end

  # Legacy all-queues fast_lookup uses stats.workers_size with no run_at filter (unlike modern JQS).
  # Pin the divergence so an accidental alignment or double-drop cannot go silent.
  def test_deprecated_queue_fast_lookup_counts_future_run_at_working
    enqueue
    enqueue_working(run_at: Time.now.to_i + 120)

    # live=1; future working excluded by modern path even with skip_working: false.
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(skip_working: false),
      "modern JQS counts live only (excludes future run_at working)"
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(server: true, skip_working: false)
    assert_equal 1, HireFire::Macro::Sidekiq.queue(skip_working: true),
      "deprecated skip_working true: live only"
    assert_equal 2, HireFire::Macro::Sidekiq.queue(skip_working: false),
      "deprecated fast_lookup includes future run_at via workers_size"
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

  # Plant a schedule/retry member with an explicit ZSET score and body timestamps.
  # Use past score + fresh body times to residual-test eligibility age (score), not payload age.
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
      case identify_redis_client(connection)
      when :redis
        connection.zadd(set_name, score, Sidekiq.dump_json(payload))
      when :redis_client
        connection.call("zadd", set_name, score, Sidekiq.dump_json(payload))
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

  # Plant a Sidekiq WorkSet entry matching processes:*:work as Sidekiq::Workers yields it:
  # { "queue" => name, "run_at" => epoch_i, "payload" => job_hash_or_json }.
  # Real Sidekiq stores payload as a JSON string of the job (processor jobstr). Nested
  # enqueued_at/created_at are aged so JQL residuals fail if WorkSet payload ages are maxed in.
  # Hash field is the job jid so multiple working plants coexist on the same process key.
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
      # payload as JSON string matches Sidekiq processor WORK_STATE (jobstr).
      worker_data = {
        "queue" => queue,
        "run_at" => run_at,
        "payload" => Sidekiq.dump_json(job_payload)
      }

      case identify_redis_client(connection)
      when :redis
        connection.sadd?("processes", process_key)
        connection.hset(process_key, "busy", "1")
        connection.hset(worker_key, jid, Sidekiq.dump_json(worker_data))
      when :redis_client
        connection.call("sadd", "processes", process_key)
        connection.call("hset", process_key, "busy", "1")
        connection.call("hset", worker_key, jid, Sidekiq.dump_json(worker_data))
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
