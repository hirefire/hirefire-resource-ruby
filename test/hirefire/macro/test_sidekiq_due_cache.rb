# frozen_string_literal: true

require "test_helper"
require "securerandom"
require "timeout"

ENV["REDIS_URL"] ||= "redis://localhost:#{ENV.fetch("REDIS_PORT", 6379)}/0"

require "sidekiq/api"

class HireFire::Macro::SidekiqDueCacheTest < Minitest::Test
  LATENCY_DELTA = 2
  Cache = HireFire::Macro::Sidekiq::DueCache

  def setup
    super
    Cache.clear_all
    Cache.begin_sample!
    Cache.trace = false
    Cache.clear_trace!
    flush_sidekiq_redis
  end

  def teardown
    Cache.trace = false
    Cache.clear_trace!
    Cache.end_sample!
    Cache.clear_all
    super
  end

  def test_multi_jql_second_call_resumes_zrange_rank
    Timecop.freeze(Time.now - 300) { enqueue_scheduled(queue: "mailer") }
    Timecop.freeze(Time.now - 100) { enqueue_scheduled(queue: "default") }

    Cache.trace = true
    Cache.clear_trace!

    assert_in_delta 300, HireFire::Macro::Sidekiq.job_queue_latency(:mailer, skip_retries: true), LATENCY_DELTA
    first_starts = schedule_start_ranks
    assert_includes first_starts, 0, "first JQL must start at rank 0"
    prior_cursor = Cache.peek("schedule").cursor_rank
    assert_equal 1, prior_cursor, "mailer is rank 0; resume cursor is 1"

    Cache.clear_trace!
    assert_in_delta 100, HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_retries: true), LATENCY_DELTA
    second_starts = schedule_start_ranks
    assert_equal [prior_cursor], second_starts, "resume must open exactly at prior cursor"
  end

  def test_n_sampler_sequential_named_jql_never_restarts_at_zero
    n = 8
    n.times do |i|
      Timecop.freeze(Time.now - (1000 - i * 10)) { enqueue_scheduled(queue: "q#{i}") }
    end

    Cache.trace = true
    n.times do |i|
      Cache.clear_trace!
      age = HireFire::Macro::Sidekiq.job_queue_latency(:"q#{i}", skip_retries: true)
      assert_in_delta 1000 - i * 10, age, LATENCY_DELTA
      starts = schedule_start_ranks
      cache = Cache.peek("schedule")
      if i.zero?
        assert_includes starts, 0, "first sampler must start at rank 0"
      elsif starts.empty?
        assert cache.oldest_at.key?("q#{i}"),
          "sampler #{i}: empty ZRANGE without oldest_at[q#{i}] is a false free-hit"
      else
        assert starts.min > 0, "sampler #{i} must resume, got #{starts.inspect}"
      end
    end

    Cache.clear_trace!
    n.times do |i|
      HireFire::Macro::Sidekiq.job_queue_latency(:"q#{i}", skip_retries: true)
    end
    assert_empty schedule_start_ranks, "second pass must free-hit every named queue"
  end

  def test_end_sample_clears_maps_and_next_wave_restarts_at_rank_zero
    plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 50, enqueued_at: Time.now.to_f)

    Cache.trace = true
    Cache.clear_trace!
    HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    assert_includes schedule_start_ranks, 0

    cache = Cache.peek("schedule")
    assert cache.complete
    assert cache.oldest_at.key?("default")
    assert cache.cursor_rank > 0
    assert_equal 1, cache.total_due

    Cache.end_sample!
    assert_nil Cache.peek("schedule"), "end_sample! must clear registry"
    refute Cache.sample_active?

    Cache.begin_sample!
    assert Cache.sample_active?
    wiped = Cache.send(:cache_for, "schedule")
    refute_same cache, wiped
    assert_equal 0, wiped.cursor_rank
    refute wiped.complete
    assert_empty wiped.oldest_at
    assert_equal 0, wiped.total_due
    assert_empty wiped.size.keys
    assert_equal 1, wiped.generation, "new wave resets generation_seq to a fresh epoch"

    Cache.clear_trace!
    HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    starts = schedule_start_ranks
    assert_includes starts, 0, "after new begin_sample!, walk must restart at rank 0"
    fresh = Cache.peek("schedule")
    refute_same cache, fresh
    assert fresh.complete
    assert_equal 1, fresh.total_due
    assert_equal 1, fresh.size["default"]
  end

  def test_out_of_band_macro_after_end_sample_does_not_free_hit
    plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 50, enqueued_at: Time.now.to_f)

    Cache.trace = true
    Cache.clear_trace!
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    assert Cache.peek("schedule").complete

    Cache.end_sample!
    refute Cache.sample_active?
    assert_nil Cache.peek("schedule")

    Cache.clear_trace!
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    starts = schedule_start_ranks
    assert_includes starts, 0, "out-of-band call must cold-walk, not free-hit prior wave"

    Cache.clear_trace!
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    assert_includes schedule_start_ranks, 0, "second out-of-band call must cold-walk again"
  end

  def test_second_begin_sample_does_not_share_first_wave_cursor
    plant_sorted_set_job("schedule", queue: "mailer", score: Time.now.to_f - 100, enqueued_at: Time.now.to_f)
    plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 50, enqueued_at: Time.now.to_f)

    HireFire::Macro::Sidekiq.job_queue_latency(:mailer, skip_retries: true)
    first = Cache.peek("schedule")
    refute first.complete
    assert first.cursor_rank > 0
    first_cursor = first.cursor_rank
    first_object_id = first.object_id

    Cache.begin_sample!
    assert_nil Cache.peek("schedule"), "second begin_sample! must clear prior wave maps"

    Cache.trace = true
    Cache.clear_trace!
    HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_retries: true)
    starts = schedule_start_ranks
    assert_equal [0], starts, "second wave must open ZRANGE at rank 0, not resume cursor #{first_cursor}"
    wave2 = Cache.peek("schedule")
    refute_equal first_object_id, wave2.object_id
  end

  def test_within_sample_wave_complete_jqs_issues_no_zrange
    3.times { |i| plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 10 - i, enqueued_at: Time.now.to_f) }

    Cache.trace = true
    Cache.clear_trace!
    assert_equal 3, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    assert_includes schedule_start_ranks, 0, "first named fill must start at rank 0"

    Cache.clear_trace!
    assert_equal 3, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    assert_empty schedule_start_ranks, "complete named cache must not rewalk within sample wave"

    Cache.clear_trace!
    assert_equal 3, HireFire::Macro::Sidekiq.job_queue_size(skip_retries: true, skip_working: true)
    assert_empty schedule_start_ranks, "all-queues JQS must not rank-walk due ZSET"
  end

  def test_jql_early_stop_then_named_jqs_extends_to_full_oracle
    Timecop.freeze(Time.now - 400) { enqueue_scheduled(queue: "foreign") }
    Timecop.freeze(Time.now - 300) { enqueue_scheduled(queue: "foreign") }
    Timecop.freeze(Time.now - 100) { enqueue_scheduled(queue: "default") }
    Timecop.freeze(Time.now - 50) { enqueue_scheduled(queue: "mailer") }

    Cache.trace = true
    Cache.clear_trace!

    assert_in_delta 100, HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_retries: true), LATENCY_DELTA
    partial = Cache.peek("schedule")
    refute partial.complete, "JQL early stop must leave complete false"
    assert_equal 2, partial.size["foreign"]
    assert_equal 1, partial.size["default"]
    refute partial.size.key?("mailer"), "must stop before later non-needed mailer"
    refute_equal 4, partial.size.values.sum, "must not treat partial map as full due region"
    prior_cursor = partial.cursor_rank
    assert_equal 3, prior_cursor, "foreign, foreign, default then early-stop"

    Cache.clear_trace!
    assert_equal 4, HireFire::Macro::Sidekiq.job_queue_size(skip_retries: true, skip_working: true)
    assert_empty schedule_start_ranks, "all-queues JQS must not rank-walk"
    assert_equal prior_cursor, Cache.peek("schedule").cursor_rank
    refute Cache.peek("schedule").complete

    Cache.clear_trace!
    size = HireFire::Macro::Sidekiq.job_queue_size(:mailer, skip_retries: true, skip_working: true)
    assert_equal 1, size
    cache = Cache.peek("schedule")
    assert cache.complete
    assert_equal 4, cache.total_due
    starts = schedule_start_ranks
    assert_equal prior_cursor, starts.min, "named JQS must resume at exact prior cursor, got #{starts.inspect}"
  end

  def test_partial_jqs_never_returned_after_foreign_prefix_jql
    Timecop.freeze(Time.now - 500) { enqueue_scheduled(queue: "zzz_last") }
    5.times { |i| Timecop.freeze(Time.now - 400 + i) { enqueue_scheduled(queue: "foreign") } }
    3.times { |i| Timecop.freeze(Time.now - 30 + i) { enqueue_scheduled(queue: "target") } }

    Cache.trace = true
    Cache.clear_trace!
    HireFire::Macro::Sidekiq.job_queue_latency(:foreign, skip_retries: true)
    partial = Cache.peek("schedule")
    refute partial.complete
    assert_equal 1, partial.size["foreign"]
    prior_cursor = partial.cursor_rank
    assert_equal 2, prior_cursor, "zzz_last then first foreign"

    Cache.clear_trace!
    size = HireFire::Macro::Sidekiq.job_queue_size(:target, skip_retries: true, skip_working: true)
    assert_equal 3, size, "named JQS must return full multi-due count, not early-stop at 1"
    assert Cache.peek("schedule").complete, "uncapped named JQS must finish due region"
    starts = schedule_start_ranks
    assert_equal prior_cursor, starts.min, "JQS must resume at exact prior cursor, got #{starts.inspect}"
  end

  def test_partial_named_jqs_does_not_serve_partial_size_key
    5.times { |i| plant_sorted_set_job("schedule", queue: "foreign", score: Time.now.to_f - 100 - i, enqueued_at: Time.now.to_f) }
    plant_sorted_set_job("schedule", queue: "later", score: Time.now.to_f - 10, enqueued_at: Time.now.to_f)

    Cache.trace = true
    Cache.clear_trace!
    HireFire::Macro::Sidekiq.job_queue_latency(:foreign, skip_retries: true)
    partial = Cache.peek("schedule")
    refute partial.complete
    assert_equal 1, partial.size["foreign"]
    prior_cursor = partial.cursor_rank
    assert_equal 1, prior_cursor

    Cache.clear_trace!
    size = HireFire::Macro::Sidekiq.job_queue_size(:foreign, skip_retries: true, skip_working: true)
    assert_equal 5, size, "must not return partial size[q] as final JQS"
    assert Cache.peek("schedule").complete
    starts = schedule_start_ranks
    assert_equal prior_cursor, starts.min, "extend walk must resume at exact prior cursor, got #{starts.inspect}"
  end

  def test_opportunistic_foreign_hit_issues_no_zrange
    Timecop.freeze(Time.now - 400) { enqueue_scheduled(queue: "foreign") }
    Timecop.freeze(Time.now - 100) { enqueue_scheduled(queue: "default") }

    Cache.trace = true
    Cache.clear_trace!
    assert_in_delta 100, HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_retries: true), LATENCY_DELTA
    partial = Cache.peek("schedule")
    assert partial.oldest_at.key?("foreign"), "walk must opportunistically record foreign"
    refute partial.complete
    assert_includes schedule_start_ranks, 0, "first walk must open at rank 0"

    Cache.clear_trace!
    foreign_age = HireFire::Macro::Sidekiq.job_queue_latency(:foreign, skip_retries: true)
    assert_in_delta 400, foreign_age, LATENCY_DELTA
    assert_empty schedule_start_ranks, "satisfied opportunistic hit must issue zero ZRANGE"

    HireFire::Macro::Sidekiq.job_queue_size(:foreign, skip_retries: true, skip_working: true)
    assert Cache.peek("schedule").complete
    Cache.clear_trace!
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:foreign, skip_retries: true, skip_working: true)
    assert_empty schedule_start_ranks
  end

  def test_score_not_age_latency_grows_without_rewalk
    frozen = Time.at(1_700_000_000)
    score = frozen.to_f - 20
    Timecop.freeze(frozen) do
      plant_sorted_set_job("schedule", queue: "default", score: score, enqueued_at: frozen.to_f)

      Cache.trace = true
      Cache.clear_trace!
      first = HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_retries: true)
      assert_in_delta 20, first, LATENCY_DELTA
      assert_includes schedule_start_ranks, 0, "first fill must produce traced ZRANGE"
      assert_in_delta score, Cache.peek("schedule").oldest_at["default"], 1e-3

      Cache.clear_trace!
      Timecop.freeze(frozen + 10) do
        second = HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_retries: true)
        assert_in_delta 30, second, LATENCY_DELTA
        assert_in_delta first + 10, second, LATENCY_DELTA
        assert_empty schedule_start_ranks, "latency read must not rewalk when oldest_at already set"
      end
    end
  end

  def test_multi_queue_one_call_stops_at_first_union_match
    Timecop.freeze(Time.now - 400) { enqueue_scheduled(queue: "mailer") }
    Timecop.freeze(Time.now - 100) { enqueue_scheduled(queue: "default") }
    Timecop.freeze(Time.now - 50) { enqueue_scheduled(queue: "low") }

    Cache.trace = true
    Cache.clear_trace!
    latency = HireFire::Macro::Sidekiq.job_queue_latency(:default, :mailer, skip_retries: true)
    assert_in_delta 400, latency, LATENCY_DELTA

    cache = Cache.peek("schedule")
    refute cache.complete
    assert cache.oldest_at.key?("mailer")
    refute cache.oldest_at.key?("default"), "must not require walking every union key"
    refute cache.oldest_at.key?("low")
    assert_equal 1, cache.cursor_rank
    assert_equal [0], schedule_start_ranks
  end

  def test_all_queues_jql_uses_first_due_score_without_rank_walk
    Timecop.freeze(Time.now - 250) { enqueue_scheduled(queue: "mailer") }
    Timecop.freeze(Time.now - 80) { enqueue_scheduled(queue: "default") }

    Cache.trace = true
    Cache.clear_trace!
    assert_in_delta 250, HireFire::Macro::Sidekiq.job_queue_latency(skip_retries: true), LATENCY_DELTA
    assert_empty schedule_start_ranks, "all-queues JQL must not rank-walk / decode due members"
    assert_nil Cache.peek("schedule"), "all-queues path must not write DueCache"

    Cache.clear_trace!
    assert_in_delta 250, HireFire::Macro::Sidekiq.job_queue_latency(skip_retries: true), LATENCY_DELTA
    assert_empty schedule_start_ranks
  end

  def test_all_queues_jqs_uses_zcount_without_rank_walk
    3.times { |i| plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 30 - i, enqueued_at: Time.now.to_f) }
    2.times { |i| plant_sorted_set_job("schedule", queue: "mailer", score: Time.now.to_f - 10 - i, enqueued_at: Time.now.to_f) }
    plant_sorted_set_job("schedule", queue: "future", score: Time.now.to_f + 60, enqueued_at: Time.now.to_f)

    Cache.trace = true
    Cache.clear_trace!
    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(skip_retries: true, skip_working: true)
    assert_empty schedule_start_ranks, "all-queues JQS must not rank-walk due ZSET"
    assert_nil Cache.peek("schedule"), "all-queues path must not write DueCache"

    Cache.clear_trace!
    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(skip_retries: true, skip_working: true)
    assert_empty schedule_start_ranks
  end

  def test_all_queues_jqs_and_jql_empty_and_future_only
    Cache.trace = true
    Cache.clear_trace!
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(skip_retries: true, skip_working: true)
    assert_equal 0.0, HireFire::Macro::Sidekiq.job_queue_latency(skip_retries: true)
    assert_empty schedule_start_ranks
    assert_nil Cache.peek("schedule")

    enqueue_scheduled_future
    Cache.clear_trace!
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(skip_retries: true, skip_working: true)
    assert_equal 0.0, HireFire::Macro::Sidekiq.job_queue_latency(skip_retries: true)
    assert_empty schedule_start_ranks
  end

  def test_all_queues_jqs_ignores_max_scheduled_walk_budget
    5.times { |i| plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 10 - i, enqueued_at: Time.now.to_f) }

    Cache.trace = true
    Cache.clear_trace!
    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(
      max_scheduled: 3,
      skip_retries: true,
      skip_working: true
    )
    assert_empty schedule_start_ranks
    assert_nil Cache.peek("schedule")

    Cache.clear_trace!
    assert_equal 5, HireFire::Macro::Sidekiq.job_queue_size(
      max_scheduled: 0,
      skip_retries: true,
      skip_working: true
    )
    assert_empty schedule_start_ranks
  end

  def test_all_queues_retry_jqs_and_jql_without_rank_walk
    Timecop.freeze(Time.now - 120) { enqueue_retry(queue: "default") }
    Timecop.freeze(Time.now - 40) { enqueue_retry(queue: "mailer") }
    enqueue_retry_future

    Cache.trace = true
    Cache.clear_trace!
    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(skip_scheduled: true, skip_working: true)
    assert_in_delta 120, HireFire::Macro::Sidekiq.job_queue_latency(skip_scheduled: true), LATENCY_DELTA
    assert_empty retry_start_ranks
    assert_nil Cache.peek("retry")
  end

  def test_skip_scheduled_and_skip_retries_do_not_walk_skipped_set
    Timecop.freeze(Time.now - 100) { enqueue_scheduled(queue: "default") }
    Timecop.freeze(Time.now - 80) { enqueue_retry(queue: "default") }

    Cache.trace = true
    Cache.clear_trace!
    age_retry_only = HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_scheduled: true)
    assert_in_delta 80, age_retry_only, LATENCY_DELTA
    ranks = Cache.zrange_start_ranks
    assert ranks.none? { |e| e[:set_name] == "schedule" }, "skip_scheduled must not walk schedule"
    assert ranks.any? { |e| e[:set_name] == "retry" }
    assert_nil Cache.peek("schedule"), "skip_scheduled must not publish schedule cache"
    refute_nil Cache.peek("retry")

    reset_wave!
    Cache.trace = true
    age_schedule_only = HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_retries: true)
    assert_in_delta 100, age_schedule_only, LATENCY_DELTA
    ranks = Cache.zrange_start_ranks
    assert ranks.none? { |e| e[:set_name] == "retry" }, "skip_retries must not walk retry"
    assert ranks.any? { |e| e[:set_name] == "schedule" }
    assert_nil Cache.peek("retry"), "skip_retries must not publish retry cache"
    refute_nil Cache.peek("schedule")
  end

  def test_retry_multi_jql_second_call_resumes_zrange_rank
    Timecop.freeze(Time.now - 300) { enqueue_retry(queue: "mailer") }
    Timecop.freeze(Time.now - 100) { enqueue_retry(queue: "default") }

    Cache.trace = true
    Cache.clear_trace!
    assert_in_delta 300, HireFire::Macro::Sidekiq.job_queue_latency(:mailer, skip_scheduled: true), LATENCY_DELTA
    first_starts = retry_start_ranks
    assert_includes first_starts, 0, "first retry JQL must start at rank 0"
    prior_cursor = Cache.peek("retry").cursor_rank
    assert_equal 1, prior_cursor

    Cache.clear_trace!
    assert_in_delta 100, HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_scheduled: true), LATENCY_DELTA
    second_starts = retry_start_ranks
    assert_equal [prior_cursor], second_starts, "retry resume must open exactly at prior cursor"
  end

  def test_max_scheduled_matching_only_no_complete_on_cap_resume
    5.times { |i| plant_sorted_set_job("schedule", queue: "foreign", score: Time.now.to_f - 100 - i, enqueued_at: Time.now.to_f) }
    4.times { |i| plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 10 - i, enqueued_at: Time.now.to_f) }

    Cache.trace = true
    Cache.clear_trace!
    capped = HireFire::Macro::Sidekiq.job_queue_size(
      :default,
      max_scheduled: 2,
      skip_retries: true,
      skip_working: true
    )
    assert_equal 2, capped
    cache = Cache.peek("schedule")
    refute cache.complete, "policy A: cap must not set complete"
    assert_equal 2, cache.size["default"]
    prior_cursor = cache.cursor_rank
    assert prior_cursor > 0

    Cache.clear_trace!
    full = HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    assert_equal 4, full
    starts = schedule_start_ranks
    assert_equal prior_cursor, starts.min, "uncapped JQS must resume at exact prior cursor, got #{starts.inspect}"
    assert Cache.peek("schedule").complete
  end

  def test_max_scheduled_zero_named_pre_loop_no_zrange
    3.times { plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 10, enqueued_at: Time.now.to_f) }
    enqueue

    Cache.trace = true
    Cache.clear_trace!
    size = HireFire::Macro::Sidekiq.job_queue_size(
      :default,
      max_scheduled: 0,
      skip_retries: true,
      skip_working: true
    )
    assert_equal 1, size, "named max_scheduled: 0 counts live only"
    assert_empty schedule_start_ranks, "named max_scheduled: 0 must short-circuit without ZRANGE"
  end

  def test_max_scheduled_after_complete_min_without_zrange
    5.times { plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 10, enqueued_at: Time.now.to_f) }

    HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    assert Cache.peek("schedule").complete

    Cache.trace = true
    Cache.clear_trace!
    assert_equal 3, HireFire::Macro::Sidekiq.job_queue_size(
      :default,
      max_scheduled: 3,
      skip_retries: true,
      skip_working: true
    )
    assert_empty schedule_start_ranks
  end

  def test_all_queues_zcount_ignores_max_scheduled_and_does_not_extend_named_cache
    3.times { |i| plant_sorted_set_job("schedule", queue: "a", score: Time.now.to_f - 30 - i, enqueued_at: Time.now.to_f) }
    2.times { |i| plant_sorted_set_job("schedule", queue: "b", score: Time.now.to_f - 5 - i, enqueued_at: Time.now.to_f) }

    Cache.trace = true
    Cache.clear_trace!
    HireFire::Macro::Sidekiq.job_queue_latency(:a, skip_retries: true)
    cache = Cache.peek("schedule")
    refute cache.complete
    assert_equal 1, cache.total_due
    assert_includes schedule_start_ranks, 0, "seed setup must open at rank 0"
    prior_cursor = cache.cursor_rank

    Cache.clear_trace!
    size = HireFire::Macro::Sidekiq.job_queue_size(
      max_scheduled: 2,
      skip_retries: true,
      skip_working: true
    )
    assert_equal 5, size
    assert_empty schedule_start_ranks, "all-queues must not rank-walk"
    assert_equal prior_cursor, Cache.peek("schedule").cursor_rank
    refute Cache.peek("schedule").complete
  end

  def test_max_scheduled_named_seed_from_size_not_total_due
    3.times { |i| plant_sorted_set_job("schedule", queue: "foreign", score: Time.now.to_f - 200 - i, enqueued_at: Time.now.to_f) }
    3.times { |i| plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 50 - i, enqueued_at: Time.now.to_f) }

    HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_retries: true)
    cache = Cache.peek("schedule")
    refute cache.complete
    assert_equal 1, cache.size["default"]
    assert cache.total_due > cache.size["default"], "foreign dues inflate total_due past named size"

    Cache.trace = true
    Cache.clear_trace!
    capped = HireFire::Macro::Sidekiq.job_queue_size(
      :default,
      max_scheduled: 2,
      skip_retries: true,
      skip_working: true
    )
    assert_equal 2, capped, "named seed from size[q] must walk to second default (not short-circuit on total_due)"
    assert schedule_start_ranks.min > 0, "must resume, got #{schedule_start_ranks.inspect}"
    refute Cache.peek("schedule").complete
  end

  def test_max_scheduled_caps_schedule_only_retry_still_full
    4.times { |i| plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 40 - i, enqueued_at: Time.now.to_f) }
    3.times { |i| plant_sorted_set_job("retry", queue: "default", score: Time.now.to_f - 20 - i, enqueued_at: Time.now.to_f) }

    Cache.trace = true
    Cache.clear_trace!
    size = HireFire::Macro::Sidekiq.job_queue_size(
      :default,
      max_scheduled: 1,
      skip_working: true
    )
    assert_equal 1 + 3, size, "cap applies to schedule only; retry fully counted"
    schedule_cache = Cache.peek("schedule")
    retry_cache = Cache.peek("retry")
    refute schedule_cache.complete, "capped schedule must stay incomplete"
    assert_equal 1, schedule_cache.size["default"]
    assert retry_cache.complete
    assert_equal 3, retry_cache.total_due

    ranks = Cache.zrange_start_ranks
    assert ranks.any? { |e| e[:set_name] == "schedule" }
    assert ranks.any? { |e| e[:set_name] == "retry" }
  end

  def test_named_empty_and_only_future_complete_with_zeros
    Cache.trace = true
    Cache.clear_trace!
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    assert_equal 0.0, HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_retries: true)
    cache = Cache.peek("schedule")
    assert cache.complete
    assert_equal 0, cache.total_due
    assert_includes schedule_start_ranks, 0, "empty named walk must still open once (empty ZRANGE)"

    Cache.clear_trace!
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    assert_equal 0.0, HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_retries: true)
    assert_empty schedule_start_ranks, "complete empty cache must not rewalk"

    reset_wave!
    enqueue_scheduled_future
    Cache.trace = true
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    assert_equal 0.0, HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_retries: true)
    assert Cache.peek("schedule").complete
    assert_includes schedule_start_ranks, 0

    Cache.clear_trace!
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    assert_empty schedule_start_ranks, "only-future complete must not rewalk"
  end

  def test_named_retry_empty_and_only_future_complete_with_zeros
    Cache.trace = true
    Cache.clear_trace!
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_scheduled: true, skip_working: true)
    assert_equal 0.0, HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_scheduled: true)
    cache = Cache.peek("retry")
    assert cache.complete
    assert_equal 0, cache.total_due
    assert_includes retry_start_ranks, 0

    Cache.clear_trace!
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_scheduled: true, skip_working: true)
    assert_empty retry_start_ranks, "complete empty retry must not rewalk"

    reset_wave!
    enqueue_retry_future
    Cache.trace = true
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_scheduled: true, skip_working: true)
    assert Cache.peek("retry").complete
    assert_includes retry_start_ranks, 0

    Cache.clear_trace!
    assert_equal 0, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_scheduled: true, skip_working: true)
    assert_empty retry_start_ranks, "only-future retry complete must not rewalk"
  end

  def test_unskipped_jql_warms_schedule_and_retry_second_free_hits_both
    Timecop.freeze(Time.now - 200) { enqueue_scheduled(queue: "default") }
    Timecop.freeze(Time.now - 150) { enqueue_retry(queue: "default") }

    Cache.trace = true
    Cache.clear_trace!
    assert_in_delta 200, HireFire::Macro::Sidekiq.job_queue_latency(:default), LATENCY_DELTA
    assert_includes schedule_start_ranks, 0
    assert_includes retry_start_ranks, 0

    Cache.clear_trace!
    assert_in_delta 200, HireFire::Macro::Sidekiq.job_queue_latency(:default), LATENCY_DELTA
    assert_empty schedule_start_ranks, "second unskipped JQL must free-hit schedule"
    assert_empty retry_start_ranks, "second unskipped JQL must free-hit retry"
  end

  def test_live_list_changes_within_sample_wave_update_jqs_and_jql
    Timecop.freeze(Time.now - 100) { enqueue_scheduled(queue: "default") }
    HireFire::Macro::Sidekiq.job_queue_size(skip_retries: true, skip_working: true)

    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(skip_retries: true, skip_working: true)

    Timecop.freeze(Time.now - 500) { enqueue }
    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(skip_retries: true, skip_working: true)
    assert_in_delta 500, HireFire::Macro::Sidekiq.job_queue_latency(skip_retries: true), LATENCY_DELTA
  end

  def test_live_bump_with_warm_due_cache_issues_no_zrange
    Timecop.freeze(Time.now - 100) { enqueue_scheduled(queue: "default") }
    HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    assert Cache.peek("schedule").complete
    due_total = Cache.peek("schedule").total_due

    Cache.trace = true
    Cache.clear_trace!
    Timecop.freeze(Time.now - 500) { enqueue }
    assert_equal due_total + 1, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    assert_empty schedule_start_ranks, "live LLEN must not rewalk warm complete due cache"
    assert_equal due_total, Cache.peek("schedule").total_due
    assert_in_delta 500, HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_retries: true), LATENCY_DELTA
    assert_empty schedule_start_ranks
  end

  def test_server_true_does_not_write_due_cache
    plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 10, enqueued_at: Time.now.to_f)
    enqueue

    assert_nil Cache.peek("schedule")
    assert_nil Cache.peek("retry")

    size = HireFire::Macro::Sidekiq.job_queue_size(server: true, skip_working: true)
    assert_equal 2, size
    assert_nil Cache.peek("schedule"), "Lua path must not publish schedule cache"
    assert_nil Cache.peek("retry")
  end

  def test_server_true_does_not_consult_or_poison_warm_cache
    plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 10, enqueued_at: Time.now.to_f)
    enqueue
    HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    warm = Cache.peek("schedule")
    refute_nil warm
    total = warm.total_due
    gen = warm.generation

    Cache.trace = true
    Cache.clear_trace!
    size = HireFire::Macro::Sidekiq.job_queue_size(server: true, skip_working: true)
    assert_equal 2, size
    assert_same warm, Cache.peek("schedule"), "server path must not replace warm cache object"
    assert_equal total, Cache.peek("schedule").total_due
    assert_equal gen, Cache.peek("schedule").generation
    assert_empty schedule_start_ranks, "server path must not walk due cache"
  end

  def test_corrupt_member_skipped_walk_continues
    plant_corrupt_sorted_set_members("schedule")
    plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 50, enqueued_at: Time.now.to_f)

    size = HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    assert_equal 1, size
    cache = Cache.peek("schedule")
    assert cache.complete
    assert_equal 1, cache.total_due
    assert_in_delta 50, HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_retries: true), LATENCY_DELTA
  end

  def test_corrupt_retry_member_skipped_walk_continues
    plant_corrupt_sorted_set_members("retry")
    plant_sorted_set_job("retry", queue: "default", score: Time.now.to_f - 50, enqueued_at: Time.now.to_f)

    size = HireFire::Macro::Sidekiq.job_queue_size(:default, skip_scheduled: true, skip_working: true)
    assert_equal 1, size
    cache = Cache.peek("retry")
    assert cache.complete
    assert_equal 1, cache.total_due
    assert_in_delta 50, HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_scheduled: true), LATENCY_DELTA
  end

  def test_missing_or_null_queue_field_skipped_like_corrupt
    now = Time.now.to_f
    plant_raw_sorted_set_member("schedule", score: now - 200, member: Sidekiq.dump_json(
      "class" => "SampleWorker", "args" => [], "jid" => "noqueue000001", "enqueued_at" => now
    ))
    plant_raw_sorted_set_member("schedule", score: now - 190, member: Sidekiq.dump_json(
      "queue" => nil, "class" => "SampleWorker", "args" => [], "jid" => "nullqueue00001", "enqueued_at" => now
    ))
    plant_raw_sorted_set_member("schedule", score: now - 180, member: Sidekiq.dump_json(
      "queue" => "", "class" => "SampleWorker", "args" => [], "jid" => "emptyqueue0001", "enqueued_at" => now
    ))
    plant_sorted_set_job("schedule", queue: "default", score: now - 50, enqueued_at: now)

    size = HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    assert_equal 1, size
    cache = Cache.peek("schedule")
    assert cache.complete
    assert_equal 1, cache.total_due
    assert_equal 1, cache.size["default"]
    assert_in_delta 50, HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_retries: true), LATENCY_DELTA
  end

  def test_same_score_multi_member_rank_resume_no_skip
    score = Time.now.to_f - 100
    plant_sorted_set_job("schedule", queue: "a", score: score, enqueued_at: Time.now.to_f, jid: "aaaaaaaaaaaa")
    plant_sorted_set_job("schedule", queue: "b", score: score, enqueued_at: Time.now.to_f, jid: "bbbbbbbbbbbb")
    plant_sorted_set_job("schedule", queue: "c", score: score + 1, enqueued_at: Time.now.to_f, jid: "cccccccccccc")

    Cache.trace = true
    Cache.clear_trace!
    HireFire::Macro::Sidekiq.job_queue_latency(:a, skip_retries: true)
    assert_equal [0], schedule_start_ranks
    cursor_after_a = Cache.peek("schedule").cursor_rank
    assert_equal 1, cursor_after_a, "known order: a is rank 0, resume at 1"

    Cache.clear_trace!
    assert_in_delta 100, HireFire::Macro::Sidekiq.job_queue_latency(:b, skip_retries: true), LATENCY_DELTA
    b_starts = schedule_start_ranks
    assert_equal [cursor_after_a], b_starts, "exact start_rank must continue at prior cursor"

    Cache.clear_trace!
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:c, skip_retries: true, skip_working: true)
    jqs_starts = schedule_start_ranks
    assert jqs_starts.min > 0, "named JQS must continue from cursor, got #{jqs_starts.inspect}"

    cache = Cache.peek("schedule")
    assert_equal 1, cache.size["a"]
    assert_equal 1, cache.size["b"]
    assert_equal 1, cache.size["c"]
    assert_equal 3, cache.total_due
  end

  def test_reinit_after_fork_replaces_mutex_and_empties_registry
    plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 10, enqueued_at: Time.now.to_f)
    HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    assert_equal 1, Cache.peek("schedule").total_due

    old_mutex = Cache.send(:mutex)
    old_condition = Cache.send(:condition)
    Cache.reinit_after_fork
    refute_same old_mutex, Cache.send(:mutex)
    refute_same old_condition, Cache.send(:condition)
    assert_nil Cache.peek("schedule")
    assert_equal 1, Cache.begin_sample!, "reinit resets wave_seq so first token is 1"

    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    peek = Cache.peek("schedule")
    assert peek.complete
    assert_equal 1, peek.total_due
  end

  def test_reinit_after_fork_with_stuck_inherited_mutex
    plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 10, enqueued_at: Time.now.to_f)
    HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)

    old_mutex = Cache.send(:mutex)
    release_holder = Queue.new
    holder = Thread.new do
      old_mutex.lock
      release_holder.pop
    ensure
      old_mutex.unlock if old_mutex.owned?
    end
    Thread.pass until old_mutex.locked?

    finished = false
    reinit_thread = Thread.new do
      Cache.reinit_after_fork
      finished = true
    end
    refute_nil reinit_thread.join(1.0), "reinit_after_fork deadlocked on stuck inherited mutex"
    assert finished
    refute_same old_mutex, Cache.send(:mutex)
    assert_nil Cache.peek("schedule")

    reset_wave!
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    assert Cache.peek("schedule").complete
  ensure
    release_holder << true if defined?(release_holder) && release_holder
    join_or_kill(holder)
  end

  def test_abandon_inherited_state_reinits_due_cache
    plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 10, enqueued_at: Time.now.to_f)
    HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    refute_nil Cache.peek("schedule")
    old_mutex = Cache.send(:mutex)

    HireFire.configuration.dispatcher.abandon_inherited_state!

    assert_nil Cache.peek("schedule"), "abandon must empty due-cache registry"
    refute_same old_mutex, Cache.send(:mutex)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    refute_nil Cache.peek("schedule")
  end

  def test_dispatcher_start_after_fork_reinits_due_cache
    stub_request(:post, "https://data.hirefire.io/metrics/lease").to_return(status: 200, body: "{}")
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 10, enqueued_at: Time.now.to_f)
    HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    refute_nil Cache.peek("schedule")
    old_mutex = Cache.send(:mutex)

    HireFire.configure { |c| c.token = "test-token" }
    dispatcher = HireFire.configuration.dispatcher
    dispatcher.start
    dispatcher.instance_variable_set(:@pid, Process.pid + 1)
    dispatcher.start

    assert_nil Cache.peek("schedule"), "start-after-fork must reinit and empty registry"
    refute_same old_mutex, Cache.send(:mutex)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    refute_nil Cache.peek("schedule")
  ensure
    dispatcher&.stop
  end

  def test_all_queues_zcount_includes_corrupt_named_walk_excludes
    Sidekiq.redis do |connection|
      case identify_redis_client(connection)
      when :redis
        connection.zadd("schedule", Time.now.to_f - 300, "{bad")
        connection.zadd("schedule", Time.now.to_f - 250, "null")
        connection.zadd("schedule", Time.now.to_f - 240, "[1]")
      when :redis_client
        connection.call("zadd", "schedule", Time.now.to_f - 300, "{bad")
        connection.call("zadd", "schedule", Time.now.to_f - 250, "null")
        connection.call("zadd", "schedule", Time.now.to_f - 240, "[1]")
      end
    end
    plant_sorted_set_job("schedule", queue: "a", score: Time.now.to_f - 20, enqueued_at: Time.now.to_f)
    plant_sorted_set_job("schedule", queue: "b", score: Time.now.to_f - 10, enqueued_at: Time.now.to_f)

    Cache.trace = true
    Cache.clear_trace!
    size = HireFire::Macro::Sidekiq.job_queue_size(skip_retries: true, skip_working: true)
    assert_equal 5, size, "all-queues ZCOUNT counts due scores without JSON filter"
    assert_empty schedule_start_ranks
    assert_nil Cache.peek("schedule")

    named = HireFire::Macro::Sidekiq.job_queue_size(:a, :b, skip_retries: true, skip_working: true)
    assert_equal 2, named, "named walk still skips corrupt members"
    cache = Cache.peek("schedule")
    assert cache.complete
    assert_equal 2, cache.total_due
    assert_equal 1, cache.size["a"]
    assert_equal 1, cache.size["b"]
  end

  def test_matching_count_named_sums_size_keys
    cache = Cache.new("schedule", now_f: Time.now.to_f, generation: 1)
    cache.record_due("a", Time.now.to_f - 20)
    cache.record_due("b", Time.now.to_f - 10)
    cache.instance_variable_set(:@total_due, 99)

    assert_equal 2, Cache.send(:matching_count, cache, %w[a b])
    assert_equal 1, Cache.send(:matching_count, cache, %w[a])
    assert_equal 0, Cache.send(:matching_count, cache, %w[missing])
  end

  def test_now_fill_freeze_excludes_members_due_only_after_fill
    t0 = Time.at(1_700_000_000)
    Timecop.freeze(t0) do
      plant_sorted_set_job("schedule", queue: "a", score: t0.to_f - 100, enqueued_at: t0.to_f)
      plant_sorted_set_job("schedule", queue: "b", score: t0.to_f + 2, enqueued_at: t0.to_f)

      HireFire::Macro::Sidekiq.job_queue_latency(:a, skip_retries: true)
      cache = Cache.peek("schedule")
      refute cache.complete
      assert_in_delta t0.to_f, cache.now_fill, 0.01

      Timecop.freeze(t0 + 3) do
        size = HireFire::Macro::Sidekiq.job_queue_size(:a, :b, skip_retries: true, skip_working: true)
        assert_equal 1, size, "member due only after now_fill must stay excluded within same wave"
        filled = Cache.peek("schedule")
        assert filled.complete
        assert_equal 1, filled.total_due
        refute filled.size.key?("b")

        reset_wave!
        size_next = HireFire::Macro::Sidekiq.job_queue_size(:a, :b, skip_retries: true, skip_working: true)
        assert_equal 2, size_next, "new wave must include member that became due after prior now_fill"
        next_cache = Cache.peek("schedule")
        assert next_cache.complete
        assert_equal 1, next_cache.size["a"]
        assert_equal 1, next_cache.size["b"]
      end
    end
  end

  def test_publish_draft_drops_when_generation_mismatches
    Cache.clear_all
    token = Object.new
    stale = Cache.new("schedule", now_f: Time.now.to_f, generation: 1)
    stale.record_due("default", Time.now.to_f - 10)
    stale.complete = true

    Cache.send(:mutex).synchronize do
      Cache.send(:generation_seq)["schedule"] = 2
      fresh = Cache.new("schedule", now_f: Time.now.to_f, generation: 2)
      Cache.send(:registry)["schedule"] = fresh
      Cache.send(:filling)["schedule"] = {
        token: token,
        generation: 1,
        started_at: Cache.now_f
      }
      Cache.send(:publish_draft!, "schedule", stale, token)
    end

    published = Cache.peek("schedule")
    assert_equal 2, published.generation
    assert_equal 0, published.total_due, "stale gen-1 draft must not overwrite gen-2 registry entry"
    refute published.complete
  end

  def test_publish_and_release_fill_require_matching_token
    Cache.clear_all
    owner = Object.new
    other = Object.new
    draft = Cache.new("schedule", now_f: Time.now.to_f, generation: 1)
    draft.record_due("poison", Time.now.to_f - 5)
    draft.complete = true

    Cache.send(:mutex).synchronize do
      Cache.send(:generation_seq)["schedule"] = 1
      baseline = Cache.new("schedule", now_f: Time.now.to_f, generation: 1)
      Cache.send(:registry)["schedule"] = baseline
      Cache.send(:filling)["schedule"] = {
        token: owner,
        generation: 1,
        started_at: Cache.now_f
      }

      Cache.send(:publish_draft!, "schedule", draft, other)
      assert_equal 0, Cache.send(:registry)["schedule"].total_due, "wrong token must not publish"
      refute Cache.send(:registry)["schedule"].complete

      Cache.send(:release_fill!, "schedule", other)
      assert Cache.send(:filling).key?("schedule"), "wrong token must not release fill entry"

      Cache.send(:release_fill!, "schedule", owner)
      refute Cache.send(:filling).key?("schedule"), "owner token must release fill entry"
    end
  end

  def test_stuck_fill_steal_walks_and_stale_token_cannot_publish
    plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 10, enqueued_at: Time.now.to_f)
    stuck_token = Object.new

    Cache.send(:mutex).synchronize do
      cache = Cache.send(:install_fresh, "schedule")
      Cache.send(:filling)["schedule"] = {
        token: stuck_token,
        generation: cache.generation,
        started_at: Cache.now_f - Cache::FILL_STUCK_SECONDS - 0.1
      }
    end

    size = HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    assert_equal 1, size, "stuck fill must be stealable so a new filler can walk"
    published = Cache.peek("schedule")
    assert published.complete
    assert_equal 1, published.total_due
    Cache.send(:mutex).synchronize do
      refute Cache.send(:filling).key?("schedule"), "successful steal+fill must release filling entry"
    end

    Cache.send(:mutex).synchronize do
      stale = Cache.new("schedule", now_f: Time.now.to_f, generation: published.generation)
      stale.record_due("poison", Time.now.to_f - 1)
      stale.complete = true
      Cache.send(:filling)["schedule"] = {
        token: Object.new,
        generation: published.generation,
        started_at: Cache.now_f
      }
      Cache.send(:publish_draft!, "schedule", stale, stuck_token)
      assert_equal 1, Cache.send(:registry)["schedule"].total_due, "stale stuck token must not overwrite stealer publish"
      refute Cache.send(:registry)["schedule"].size.key?("poison")
      Cache.send(:filling).delete("schedule")
    end
  end

  def test_successful_walk_releases_fill_entry
    plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 10, enqueued_at: Time.now.to_f)
    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    Cache.send(:mutex).synchronize do
      refute Cache.send(:filling).key?("schedule"), "ensure release after walk"
    end
  end

  def test_concurrent_single_flight_walks_once
    2.times do |i|
      plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 10 - i, enqueued_at: Time.now.to_f)
    end

    mid = Queue.new
    release = Queue.new
    waiter_parked = Queue.new
    zrange_count = 0
    count_mu = Mutex.new
    sizes = []
    errors = []
    t1 = t2 = nil

    condition = Cache.send(:condition)
    original_wait = condition.method(:wait)
    condition.define_singleton_method(:wait) do |mutex, timeout = nil|
      waiter_parked << true
      original_wait.call(mutex, timeout)
    end

    with_zrange_batch_hook(->(_set, _rank, &original) {
      n = count_mu.synchronize {
        zrange_count += 1
        zrange_count
      }
      if n == 1
        mid << true
        release.pop
      end
      original.call
    }) do
      t1 = Thread.new {
        begin
          sizes[0] = HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
        rescue => e
          errors << e
        end
      }
      Timeout.timeout(2) { mid.pop }

      t2 = Thread.new {
        begin
          sizes[1] = HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
        rescue => e
          errors << e
        end
      }
      Timeout.timeout(2) { waiter_parked.pop }
      assert_equal 1, count_mu.synchronize { zrange_count }, "waiter must not start a second walk"

      release << true
      Timeout.timeout(3) {
        t1.join
        t2.join
      }
      assert_empty errors
      assert_equal 2, sizes[0]
      assert_equal 2, sizes[1]
      assert_equal 2, Cache.peek("schedule").total_due
      assert_equal 2, zrange_count, "single-flight must walk Redis once for both callers"
    end
  ensure
    release << true if defined?(release) && release
    [t1, t2].each { |t| join_or_kill(t) }
    recover_due_cache_after_concurrency!
  end

  def test_waiter_timed_condition_wait_then_observes_fill
    plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 10, enqueued_at: Time.now.to_f)

    mid = Queue.new
    release = Queue.new
    waiter_entered_wait = Queue.new
    wait_timeouts = []
    wait_returns = 0
    wait_mu = Mutex.new
    zrange_count = 0
    count_mu = Mutex.new
    filler_size = waiter_size = nil
    errors = []
    filler = waiter = nil

    condition = Cache.send(:condition)
    original_wait = condition.method(:wait)
    condition.define_singleton_method(:wait) do |mutex, timeout = nil|
      wait_timeouts << timeout
      waiter_entered_wait << true
      result = original_wait.call(mutex, timeout)
      wait_mu.synchronize { wait_returns += 1 }
      result
    end

    with_zrange_batch_hook(->(_set, _rank, &original) {
      n = count_mu.synchronize {
        zrange_count += 1
        zrange_count
      }
      if n == 1
        mid << true
        release.pop
      end
      original.call
    }) do
      filler = Thread.new {
        begin
          filler_size = HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
        rescue => e
          errors << e
        end
      }
      Timeout.timeout(2) { mid.pop }

      waiter = Thread.new {
        begin
          waiter_size = HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
        rescue => e
          errors << e
        end
      }
      Timeout.timeout(2) { waiter_entered_wait.pop }
      deadline = Time.now + Cache::FILL_WAIT_SECONDS + 0.25
      sleep [deadline - Time.now, 0].max until wait_mu.synchronize { wait_returns } >= 1 || Time.now > deadline
      assert wait_mu.synchronize { wait_returns } >= 1,
        "waiter must return from timed wait at least once, timeouts=#{wait_timeouts.inspect}"
      assert_equal 1, count_mu.synchronize { zrange_count },
        "after timed wake, non-stuck fill must keep waiter non-filler"
      release << true

      Timeout.timeout(Cache::FILL_WAIT_SECONDS + 3) {
        filler.join
        waiter.join
      }
      assert_empty errors
      assert_equal 1, filler_size
      assert_equal 1, waiter_size
      assert wait_timeouts.any? { |t| t == Cache::FILL_WAIT_SECONDS },
        "waiter must call condition.wait with FILL_WAIT_SECONDS, got #{wait_timeouts.inspect}"
      assert_equal 2, zrange_count, "timed waiter must not steal a second walk before FILL_STUCK"
    end
  ensure
    release << true if defined?(release) && release
    [filler, waiter].each { |t| join_or_kill(t) }
    recover_due_cache_after_concurrency!
  end

  def test_release_fill_broadcast_wakes_waiter_before_fill_wait
    plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 10, enqueued_at: Time.now.to_f)

    mid = Queue.new
    release = Queue.new
    waiter_parked = Queue.new
    zrange_count = 0
    count_mu = Mutex.new
    filler_size = waiter_size = nil
    errors = []
    filler = waiter = nil

    condition = Cache.send(:condition)
    original_wait = condition.method(:wait)
    condition.define_singleton_method(:wait) do |mutex, timeout = nil|
      waiter_parked << true
      original_wait.call(mutex, timeout)
    end

    with_zrange_batch_hook(->(_set, _rank, &original) {
      n = count_mu.synchronize {
        zrange_count += 1
        zrange_count
      }
      if n == 1
        mid << true
        release.pop
      end
      original.call
    }) do
      filler = Thread.new {
        begin
          filler_size = HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
        rescue => e
          errors << e
        end
      }
      Timeout.timeout(2) { mid.pop }

      started = Time.now
      waiter = Thread.new {
        begin
          waiter_size = HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
        rescue => e
          errors << e
        end
      }
      Timeout.timeout(2) { waiter_parked.pop }
      release << true
      Timeout.timeout(2) {
        filler.join
        waiter.join
      }
      elapsed = Time.now - started
      assert_empty errors
      assert_equal 1, filler_size
      assert_equal 1, waiter_size
      assert elapsed < Cache::FILL_WAIT_SECONDS,
        "release_fill! broadcast must wake waiter before FILL_WAIT, elapsed=#{elapsed}"
      assert_equal 2, zrange_count
    end
  ensure
    release << true if defined?(release) && release
    [filler, waiter].each { |t| join_or_kill(t) }
    recover_due_cache_after_concurrency!
  end

  def test_begin_end_clear_broadcast_wake_parked_waiters
    {
      begin_sample!: -> { Cache.begin_sample! },
      end_sample!: -> { Cache.end_sample! },
      clear_all: -> { Cache.clear_all }
    }.each do |label, trigger|
      parked = Queue.new
      finished = Queue.new
      errors = []
      waiter = nil
      begin
        waiter = Thread.new {
          begin
            Cache.send(:mutex).synchronize do
              parked << true
              Cache.send(:condition).wait(Cache.send(:mutex), Cache::FILL_WAIT_SECONDS)
            end
            finished << true
          rescue => e
            errors << e
          end
        }
        Timeout.timeout(2) { parked.pop }
        started = Time.now
        trigger.call
        Timeout.timeout(0.5) { finished.pop }
        elapsed = Time.now - started
        assert_empty errors, "#{label} wake raised"
        assert elapsed < 0.5, "#{label} must broadcast-wake waiter, elapsed=#{elapsed}"
      ensure
        join_or_kill(waiter)
        recover_due_cache_after_concurrency!
      end
    end
  end

  def test_stuck_fill_steal_with_live_hung_filler
    plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 10, enqueued_at: Time.now.to_f)

    mid = Queue.new
    release = Queue.new
    zrange_count = 0
    count_mu = Mutex.new
    filler_size = stealer_size = nil
    errors = []
    filler = stealer = nil
    stuck_token = nil

    with_zrange_batch_hook(->(_set, _rank, &original) {
      n = count_mu.synchronize {
        zrange_count += 1
        zrange_count
      }
      if n == 1
        mid << true
        release.pop
      end
      original.call
    }) do
      filler = Thread.new {
        begin
          filler_size = HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
        rescue => e
          errors << e
        end
      }
      Timeout.timeout(2) { mid.pop }

      Cache.send(:mutex).synchronize do
        entry = Cache.send(:filling)["schedule"]
        refute_nil entry, "filler must own filling while mid-zrange"
        stuck_token = entry[:token]
        entry[:started_at] = Cache.now_f - Cache::FILL_STUCK_SECONDS - 0.1
      end

      stealer = Thread.new {
        begin
          stealer_size = HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
        rescue => e
          errors << e
        end
      }
      Timeout.timeout(3) { stealer.join }

      assert_equal 1, stealer_size, "stealer must complete a full walk after stuck steal"
      published = Cache.peek("schedule")
      assert published.complete
      assert_equal 1, published.total_due
      assert zrange_count >= 3, "stealer must walk Redis (data + empty) while original hung"

      plant_sorted_set_job(
        "schedule",
        queue: "poison",
        score: Time.now.to_f - 5,
        enqueued_at: Time.now.to_f,
        jid: "poisonmember1"
      )

      release << true
      Timeout.timeout(2) { filler.join }
      assert_empty errors
      assert filler_size >= 1
      assert_same published, Cache.peek("schedule"), "hung token must not replace stealer registry object"
      assert_equal 1, Cache.peek("schedule").total_due, "hung publish must not install poison due"
      refute Cache.peek("schedule").size.key?("poison")
    end
  ensure
    release << true if defined?(release) && release
    [filler, stealer].each { |t| join_or_kill(t) }
    recover_due_cache_after_concurrency!
  end

  def test_concurrent_jql_filler_jqs_waiter_parks_then_extends
    Timecop.freeze(Time.now - 400) { enqueue_scheduled(queue: "foreign") }
    Timecop.freeze(Time.now - 100) { enqueue_scheduled(queue: "default") }

    mid = Queue.new
    release = Queue.new
    waiter_parked = Queue.new
    zrange_count = 0
    count_mu = Mutex.new
    jql_age = jqs_size = nil
    errors = []
    filler = waiter = nil

    condition = Cache.send(:condition)
    original_wait = condition.method(:wait)
    condition.define_singleton_method(:wait) do |mutex, timeout = nil|
      waiter_parked << true
      original_wait.call(mutex, timeout)
    end

    with_zrange_batch_hook(->(_set, _rank, &original) {
      n = count_mu.synchronize {
        zrange_count += 1
        zrange_count
      }
      if n == 1
        mid << true
        release.pop
      end
      original.call
    }) do
      filler = Thread.new {
        begin
          jql_age = HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_retries: true)
        rescue => e
          errors << e
        end
      }
      Timeout.timeout(2) { mid.pop }

      waiter = Thread.new {
        begin
          jqs_size = HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
        rescue => e
          errors << e
        end
      }
      Timeout.timeout(2) { waiter_parked.pop }
      assert_equal 1, count_mu.synchronize { zrange_count }, "JQS waiter must park during JQL fill"

      release << true
      Timeout.timeout(3) {
        filler.join
        waiter.join
      }
      assert_empty errors
      assert_in_delta 100, jql_age, LATENCY_DELTA
      assert_equal 1, jqs_size, "named JQS returns default dues only after extend completes"
      cache = Cache.peek("schedule")
      assert cache.complete
      assert_equal 2, cache.total_due, "extend must still visit foreign + default"
      assert_equal 2, zrange_count,
        "mixed-mode: one JQL batch then JQS empty-complete extend, got #{zrange_count}"
    end
  ensure
    release << true if defined?(release) && release
    [filler, waiter].each { |t| join_or_kill(t) }
    recover_due_cache_after_concurrency!
  end

  def test_ensure_walk_returns_draft_not_registry_repeek
    plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 10, enqueued_at: Time.now.to_f)

    owner = Cache.singleton_class
    original_walk = owner.instance_method(:walk!)
    owner.define_method(:walk!) do |cache, mode:, needed:, max_scheduled: nil|
      result = original_walk.bind_call(self, cache, mode: mode, needed: needed, max_scheduled: max_scheduled)
      mutex.synchronize { install_fresh(cache.set_name) }
      result
    end

    size = HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    assert_equal 1, size, "must return filled draft; re-peek of fresh registry would yield 0"
    fresh = Cache.peek("schedule")
    assert_equal 0, fresh.total_due
    refute fresh.complete

    Cache.clear_trace!
    Cache.trace = true
    latency = HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_retries: true)
    assert_in_delta 10, latency, LATENCY_DELTA
    assert_includes schedule_start_ranks, 0, "post-TOCTOU latency must cold-open at rank 0"
  ensure
    owner = Cache.singleton_class
    if defined?(original_walk) && original_walk
      owner.define_method(:walk!, original_walk)
    end
  end

  def test_walk_raise_releases_filling_entry
    plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 10, enqueued_at: Time.now.to_f)

    with_zrange_batch_hook(->(*) { raise "zrange boom" }) do
      error = assert_raises(RuntimeError) {
        HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
      }
      assert_match(/zrange boom/, error.message)
    end

    Cache.send(:mutex).synchronize do
      refute Cache.send(:filling).key?("schedule"), "ensure must release filling after walk! raise"
    end

    assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    assert Cache.peek("schedule").complete
  end

  def test_begin_sample_sets_active_and_clears_registry
    plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 10, enqueued_at: Time.now.to_f)
    HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    refute_nil Cache.peek("schedule")

    Cache.begin_sample!
    assert Cache.sample_active?
    assert_nil Cache.peek("schedule")
    Cache.send(:mutex).synchronize do
      assert_empty Cache.send(:filling)
      assert_empty Cache.send(:generation_seq)
    end
  end

  def test_maps_survive_continue_walk_until_end_sample
    plant_sorted_set_job("schedule", queue: "a", score: Time.now.to_f - 50, enqueued_at: Time.now.to_f)
    plant_sorted_set_job("schedule", queue: "b", score: Time.now.to_f - 40, enqueued_at: Time.now.to_f)

    Cache.trace = true
    Cache.clear_trace!
    HireFire::Macro::Sidekiq.job_queue_latency(:a, skip_retries: true)
    first = Cache.peek("schedule")
    refute first.complete
    gen = first.generation
    cursor = first.cursor_rank
    assert_equal 1, cursor, "a is oldest (rank 0), resume cursor is 1"
    assert_equal [0], schedule_start_ranks

    Cache.clear_trace!
    HireFire::Macro::Sidekiq.job_queue_latency(:a, skip_retries: true)
    assert_same first, Cache.peek("schedule"), "free-hit must keep same registry object"
    assert_equal cursor, Cache.peek("schedule").cursor_rank
    assert_empty schedule_start_ranks, "satisfied :a free-hit issues no ZRANGE"

    Cache.clear_trace!
    HireFire::Macro::Sidekiq.job_queue_latency(:b, skip_retries: true)
    second = Cache.peek("schedule")
    assert second.oldest_at.key?("b")
    assert_equal gen, second.generation, "continue-walk keeps same epoch generation"
    assert_equal [cursor], schedule_start_ranks, "continue for :b must resume at prior cursor"
    assert_operator second.cursor_rank, :>, cursor

    Cache.end_sample!
    assert_nil Cache.peek("schedule")
  end

  def test_dispatcher_sample_job_queues_ends_wave_when_sampler_raises
    plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 10, enqueued_at: Time.now.to_f)

    Cache.end_sample!
    Cache.clear_all
    refute Cache.sample_active?

    dispatcher = HireFire.configuration.dispatcher
    lease = dispatcher.instance_variable_get(:@lease)
    prior_granted = lease.granted?
    prior_queues = lease.job_queues
    lease.instance_variable_set(:@granted, true)
    lease.instance_variable_set(:@job_queues, [
      {
        "name" => "worker",
        "adapter" => "sidekiq",
        "strategy" => "jqs",
        "queues" => ["default"],
        "options" => {"skip_working" => true, "skip_retries" => true}
      }
    ])

    saw_active = false
    owner = HireFire::Plan.singleton_class
    original = owner.instance_method(:execute)
    owner.define_method(:execute) do |_entry, _live = nil|
      saw_active = Cache.sample_active?
      HireFire::Macro::Sidekiq.job_queue_size(
        :default,
        skip_retries: true,
        skip_working: true
      )
      raise "sampler boom"
    end

    error = assert_raises(RuntimeError) { dispatcher.send(:sample_job_queues) }
    assert_match(/sampler boom/, error.message)
    assert saw_active, "dispatcher must open a sample wave before plan execute"
    refute Cache.sample_active?, "ensure must end_sample! after raising sampler"
    assert_nil Cache.peek("schedule"), "ensure must clear registry after raise"
  ensure
    if defined?(original) && original
      HireFire::Plan.singleton_class.define_method(:execute, original)
    end
    if defined?(lease) && lease
      lease.instance_variable_set(:@granted, prior_granted)
      lease.instance_variable_set(:@job_queues, prior_queues)
    end
  end

  def test_dispatcher_sample_job_queues_amortizes_across_plan_entries
    plant_sorted_set_job("schedule", queue: "mailer", score: Time.now.to_f - 300, enqueued_at: Time.now.to_f)
    plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 100, enqueued_at: Time.now.to_f)

    Cache.end_sample!
    Cache.clear_all
    refute Cache.sample_active?

    dispatcher = HireFire.configuration.dispatcher
    lease = dispatcher.instance_variable_get(:@lease)
    prior_granted = lease.granted?
    prior_queues = lease.job_queues
    lease.instance_variable_set(:@granted, true)
    lease.instance_variable_set(:@job_queues, [
      {
        "name" => "mailer",
        "adapter" => "sidekiq",
        "strategy" => "jql",
        "queues" => ["mailer"],
        "options" => {"skip_retries" => true}
      },
      {
        "name" => "default",
        "adapter" => "sidekiq",
        "strategy" => "jql",
        "queues" => ["default"],
        "options" => {"skip_retries" => true}
      }
    ])

    Cache.trace = true
    Cache.clear_trace!
    dispatcher.send(:sample_job_queues)

    starts = schedule_start_ranks
    assert_equal [0, 1], starts, "first plan entry rank 0, second resumes at cursor 1, got #{starts.inspect}"

    refute Cache.sample_active?, "sample_job_queues must end the wave on return"
    assert_nil Cache.peek("schedule"), "end_sample! must clear maps after happy path"
  ensure
    if defined?(lease) && lease
      lease.instance_variable_set(:@granted, prior_granted)
      lease.instance_variable_set(:@job_queues, prior_queues)
    end
  end

  def test_stale_end_sample_wave_token_does_not_clear_live_wave
    plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 10, enqueued_at: Time.now.to_f)

    wave1 = Cache.begin_sample!
    HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    assert Cache.peek("schedule").complete

    wave2 = Cache.begin_sample!
    refute_equal wave1, wave2
    assert_nil Cache.peek("schedule")
    HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    live = Cache.peek("schedule")
    refute_nil live
    assert live.complete
    gen = live.generation

    cleared = Cache.end_sample!(wave1)
    refute cleared, "stale wave token must not clear live wave"
    assert Cache.sample_active?
    assert_same live, Cache.peek("schedule")
    assert_equal gen, Cache.peek("schedule").generation

    assert Cache.end_sample!(wave2)
    refute Cache.sample_active?
    assert_nil Cache.peek("schedule")
  end

  def test_end_sample_mid_zrange_drops_stale_publish
    plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 10, enqueued_at: Time.now.to_f)
    plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 9, enqueued_at: Time.now.to_f)

    mid = Queue.new
    release = Queue.new
    errors = []
    size = nil
    zrange_count = 0
    count_mu = Mutex.new
    filler = nil

    with_zrange_batch_hook(->(_set, _rank, &original) {
      n = count_mu.synchronize {
        zrange_count += 1
        zrange_count
      }
      if n == 1
        mid << true
        release.pop
      end
      original.call
    }) do
      filler = Thread.new {
        begin
          size = HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
        rescue => e
          errors << e
        end
      }
      Timeout.timeout(2) { mid.pop }

      Cache.end_sample!
      refute Cache.sample_active?
      release << true
      Timeout.timeout(3) { filler.join }

      assert_empty errors
      assert_nil Cache.peek("schedule"), "publish after end_sample! must not reinstall maps"
      assert_equal 2, size
    end
  ensure
    release << true if defined?(release) && release
    join_or_kill(filler)
    recover_due_cache_after_concurrency!
  end

  def test_begin_sample_mid_zrange_invalidates_stale_fill_generation
    plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 10, enqueued_at: Time.now.to_f)

    mid = Queue.new
    release = Queue.new
    errors = []
    first_size = nil
    zrange_count = 0
    count_mu = Mutex.new
    filler = nil

    with_zrange_batch_hook(->(_set, _rank, &original) {
      n = count_mu.synchronize {
        zrange_count += 1
        zrange_count
      }
      if n == 1
        mid << true
        release.pop
      end
      original.call
    }) do
      filler = Thread.new {
        begin
          first_size = HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
        rescue => e
          errors << e
        end
      }
      Timeout.timeout(2) { mid.pop }

      wave2 = Cache.begin_sample!
      refute_nil wave2
      assert Cache.sample_active?
      assert_nil Cache.peek("schedule")

      release << true
      Timeout.timeout(3) { filler.join }
      assert_empty errors
      assert_nil Cache.peek("schedule"), "stale fill from pre-begin wave must not publish into new wave"
      assert_equal 1, first_size

      Cache.clear_trace!
      Cache.trace = true
      assert_equal 1, HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
      assert_includes schedule_start_ranks, 0
      assert Cache.peek("schedule").complete
    end
  ensure
    release << true if defined?(release) && release
    join_or_kill(filler)
    recover_due_cache_after_concurrency!
  end

  def test_jqs_skip_scheduled_and_skip_retries_isolation
    Timecop.freeze(Time.now - 100) { enqueue_scheduled(queue: "default") }
    Timecop.freeze(Time.now - 80) { enqueue_retry(queue: "default") }
    enqueue

    Cache.trace = true
    Cache.clear_trace!
    size_retry_only = HireFire::Macro::Sidekiq.job_queue_size(
      :default,
      skip_scheduled: true,
      skip_working: true
    )
    assert_equal 2, size_retry_only
    ranks = Cache.zrange_start_ranks
    assert ranks.none? { |e| e[:set_name] == "schedule" }, "JQS skip_scheduled must not walk schedule"
    assert ranks.any? { |e| e[:set_name] == "retry" }
    assert_nil Cache.peek("schedule")
    refute_nil Cache.peek("retry")

    reset_wave!
    Cache.trace = true
    size_schedule_only = HireFire::Macro::Sidekiq.job_queue_size(
      :default,
      skip_retries: true,
      skip_working: true
    )
    assert_equal 2, size_schedule_only
    ranks = Cache.zrange_start_ranks
    assert ranks.none? { |e| e[:set_name] == "retry" }, "JQS skip_retries must not walk retry"
    assert ranks.any? { |e| e[:set_name] == "schedule" }
    assert_nil Cache.peek("retry")
    refute_nil Cache.peek("schedule")
  end

  def test_batch_boundary_multi_batch_rank_and_resume
    batch = Cache::BATCH
    now = Time.now.to_f
    plant_sorted_set_jobs_bulk(
      "schedule",
      count: batch,
      queue: "foreign",
      score_start: now - 500,
      score_step: 0.001,
      enqueued_at: now
    )
    plant_sorted_set_job("schedule", queue: "target", score: now - 10, enqueued_at: now)

    Cache.trace = true
    Cache.clear_trace!
    assert_in_delta 10, HireFire::Macro::Sidekiq.job_queue_latency(:target, skip_retries: true), LATENCY_DELTA
    starts = schedule_start_ranks
    assert_includes starts, 0
    assert_includes starts, batch, "must open a second ZRANGE at BATCH boundary, got #{starts.inspect}"
    assert_equal [0, batch], starts

    reset_wave!
    flush_sidekiq_redis
    Cache.trace = true
    plant_sorted_set_job("schedule", queue: "foreign", score: now - 600, enqueued_at: now, jid: "earlyforeign01")
    plant_sorted_set_jobs_bulk(
      "schedule",
      count: batch,
      queue: "foreign",
      score_start: now - 500,
      score_step: 0.001,
      enqueued_at: now
    )
    plant_sorted_set_job("schedule", queue: "target", score: now - 10, enqueued_at: now, jid: "targetqueue01")

    HireFire::Macro::Sidekiq.job_queue_latency(:foreign, skip_retries: true)
    assert_equal [0], schedule_start_ranks
    cursor = Cache.peek("schedule").cursor_rank
    assert_equal 1, cursor

    Cache.clear_trace!
    assert_in_delta 10, HireFire::Macro::Sidekiq.job_queue_latency(:target, skip_retries: true), LATENCY_DELTA
    resume_starts = schedule_start_ranks
    assert_equal [1, 1 + batch], resume_starts, "resume must cross a full BATCH after cursor"
  end

  def test_reinit_after_fork_clears_filling_and_generation
    Cache.begin_sample!
    Cache.send(:mutex).synchronize do
      Cache.send(:filling)["schedule"] = {
        token: Object.new,
        generation: 1,
        started_at: Cache.now_f
      }
      Cache.send(:generation_seq)["schedule"] = 7
      Cache.send(:registry)["schedule"] = Cache.new("schedule", now_f: Time.now.to_f, generation: 7)
    end

    Cache.reinit_after_fork

    refute Cache.sample_active?
    Cache.send(:mutex).synchronize do
      assert_empty Cache.send(:filling)
      assert_empty Cache.send(:generation_seq)
      assert_empty Cache.send(:registry)
    end
  end

  def test_dup_for_fill_isolates_draft_from_registry_peek
    Cache.send(:mutex).synchronize do
      cache = Cache.send(:install_fresh, "schedule")
      draft = cache.dup_for_fill
      draft.record_due("default", Time.now.to_f - 10)
      draft.complete = true

      assert_equal 0, cache.total_due
      refute cache.complete
      assert_equal 0, Cache.send(:registry)["schedule"].total_due,
        "mid-fill draft mutations must not be visible via registry/peek until publish"
      assert_equal 1, draft.total_due
    end
  end

  def test_score_equal_now_fill_counts_as_due
    t0 = Time.at(1_700_000_000)
    Timecop.freeze(t0) do
      plant_sorted_set_job("schedule", queue: "default", score: t0.to_f, enqueued_at: t0.to_f)
      size = HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
      assert_equal 1, size, "score == now_fill must be included (cut is score > now_fill)"
      assert_equal 1, Cache.peek("schedule").total_due
    end
  end

  def test_max_scheduled_named_after_complete_min_without_zrange
    4.times do |i|
      plant_sorted_set_job("schedule", queue: "default", score: Time.now.to_f - 10 - i, enqueued_at: Time.now.to_f)
    end
    HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    assert Cache.peek("schedule").complete

    Cache.trace = true
    Cache.clear_trace!
    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(
      :default,
      max_scheduled: 2,
      skip_retries: true,
      skip_working: true
    )
    assert_empty schedule_start_ranks
  end

  private

  class SampleWorker
    include Sidekiq::Worker

    def perform
    end
  end

  def reset_wave!
    Cache.clear_all
    Cache.begin_sample!
    Cache.clear_trace!
  end

  def schedule_start_ranks
    Cache.zrange_start_ranks
      .select { |e| e[:set_name] == "schedule" }
      .map { |e| e[:start_rank] }
  end

  def retry_start_ranks
    Cache.zrange_start_ranks
      .select { |e| e[:set_name] == "retry" }
      .map { |e| e[:start_rank] }
  end

  def join_or_kill(thread, timeout = 1.0)
    return if thread.nil?

    thread.join(timeout) || begin
      thread.kill
      thread.join(0.5)
    end
  end

  # Full reinit after concurrent tests that may Thread#kill while holding the mutex.
  def recover_due_cache_after_concurrency!
    Cache.reinit_after_fork
    Cache.begin_sample!
    Cache.trace = false
    Cache.clear_trace!
  end

  def plant_corrupt_sorted_set_members(set_name)
    Sidekiq.redis do |connection|
      case identify_redis_client(connection)
      when :redis
        connection.zadd(set_name, Time.now.to_f - 200, "not-json")
        connection.zadd(set_name, Time.now.to_f - 150, "null")
        connection.zadd(set_name, Time.now.to_f - 140, "[1]")
        connection.zadd(set_name, Time.now.to_f - 130, "true")
      when :redis_client
        connection.call("zadd", set_name, Time.now.to_f - 200, "not-json")
        connection.call("zadd", set_name, Time.now.to_f - 150, "null")
        connection.call("zadd", set_name, Time.now.to_f - 140, "[1]")
        connection.call("zadd", set_name, Time.now.to_f - 130, "true")
      end
    end
  end

  # Monkeypatch private zrange_batch for the block; always restore.
  def with_zrange_batch_hook(hook)
    owner = Cache.singleton_class
    original = owner.instance_method(:zrange_batch)
    owner.define_method(:zrange_batch) do |set_name, rank|
      hook.call(set_name, rank) { original.bind_call(self, set_name, rank) }
    end
    yield
  ensure
    owner.define_method(:zrange_batch, original) if original
  end

  def plant_sorted_set_jobs_bulk(set_name, count:, queue:, score_start:, score_step:, enqueued_at:)
    Sidekiq.redis do |connection|
      case identify_redis_client(connection)
      when :redis
        connection.pipelined do |pipe|
          count.times do |i|
            payload = Sidekiq.dump_json(
              "queue" => queue,
              "class" => "SampleWorker",
              "args" => [],
              "jid" => format("bulk%010d", i),
              "enqueued_at" => enqueued_at
            )
            pipe.zadd(set_name, score_start + i * score_step, payload)
          end
        end
      when :redis_client
        count.times do |i|
          payload = Sidekiq.dump_json(
            "queue" => queue,
            "class" => "SampleWorker",
            "args" => [],
            "jid" => format("bulk%010d", i),
            "enqueued_at" => enqueued_at
          )
          connection.call("zadd", set_name, score_start + i * score_step, payload)
        end
      end
    end
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

  def plant_sorted_set_job(set_name, score:, enqueued_at:, queue: "default", created_at: nil, jid: nil)
    payload = {
      "queue" => queue,
      "class" => "SampleWorker",
      "args" => [],
      "jid" => jid || SecureRandom.hex(12),
      "enqueued_at" => enqueued_at
    }
    payload["created_at"] = created_at unless created_at.nil?

    plant_raw_sorted_set_member(set_name, score: score, member: Sidekiq.dump_json(payload))
  end

  def plant_raw_sorted_set_member(set_name, score:, member:)
    Sidekiq.redis do |connection|
      case identify_redis_client(connection)
      when :redis
        connection.zadd(set_name, score, member)
      when :redis_client
        connection.call("zadd", set_name, score, member)
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
