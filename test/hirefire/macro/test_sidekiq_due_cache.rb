# frozen_string_literal: true

require "test_helper"
require "securerandom"

ENV["REDIS_URL"] ||= "redis://127.0.0.1:#{ENV.fetch("REDIS_PORT", 6379)}/0"

require "sidekiq/api"

class HireFire::Macro::SidekiqDueCacheTest < Minitest::Test
  LATENCY_DELTA = 2
  Cache = HireFire::Macro::Sidekiq::DueCache
  Macro = HireFire::Macro::Sidekiq
  SCHEDULE = {skip_retries: true}.freeze
  SCHEDULE_SIZE = {skip_retries: true, skip_working: true}.freeze
  RETRY_SIZE = {skip_scheduled: true, skip_working: true}.freeze

  module ZrangeLog
    CALLS = []
    RANGES = []

    def zrange(key, start, *rest)
      CALLS << [key, start]
      RANGES << [key, start, rest.first]
      super
    end
  end
  Sidekiq::RedisClientAdapter::CompatClient.prepend(ZrangeLog)

  class SampleWorker
    include Sidekiq::Job

    def perform
    end
  end

  def setup
    super
    Sidekiq.redis do |connection|
      connection.call("flushdb")
      connection.call("script", "flush")
    end
    @round = Cache.begin_sample!
    ZrangeLog::CALLS.clear
    ZrangeLog::RANGES.clear
  end

  def teardown
    Cache.end_sample!
    super
  end

  def test_a_second_latency_call_of_a_round_reads_on_from_where_the_first_stopped
    plant("schedule", queue: "mailer", age: 300)
    plant("schedule", queue: "default", age: 100)

    assert_in_delta 300, Macro.job_queue_latency(:mailer, **SCHEDULE), LATENCY_DELTA
    assert_equal [0], reads("schedule")

    assert_in_delta 100, Macro.job_queue_latency(:default, **SCHEDULE), LATENCY_DELTA
    assert_equal [0, 1], reads("schedule")
  end

  def test_each_entry_of_a_round_reads_on_and_none_starts_over
    %w[a b c d].each_with_index { |queue, index| plant("schedule", queue: queue, age: 400 - index * 100) }

    ages = %w[a b c d].map { |queue| Macro.job_queue_latency(queue, **SCHEDULE) }

    ages.zip([400, 300, 200, 100]).each { |age, expected| assert_in_delta expected, age, LATENCY_DELTA }
    assert_equal [0, 1, 2, 3], reads("schedule")
  end

  def test_a_queue_seen_on_the_way_to_another_costs_no_further_read
    plant("schedule", queue: "mailer", age: 300)
    plant("schedule", queue: "default", age: 100)

    assert_in_delta 100, Macro.job_queue_latency(:default, **SCHEDULE), LATENCY_DELTA
    assert_in_delta 300, Macro.job_queue_latency(:mailer, **SCHEDULE), LATENCY_DELTA

    assert_equal [0], reads("schedule")
  end

  def test_a_latency_call_for_several_queues_stops_at_the_oldest_job_of_any_of_them
    plant("schedule", queue: "other", age: 400)
    plant("schedule", queue: "mailer", age: 300)
    3.times { plant("schedule", queue: "default", age: 100) }

    with_batch(2) do
      assert_in_delta 300, Macro.job_queue_latency(:default, :mailer, **SCHEDULE), LATENCY_DELTA
    end

    assert_equal [0], reads("schedule")
  end

  def test_a_latency_grows_with_the_clock_without_another_read
    plant("schedule", queue: "default", age: 100)

    assert_in_delta 100, Macro.job_queue_latency(:default, **SCHEDULE), LATENCY_DELTA
    Timecop.freeze(Time.now + 50) do
      assert_in_delta 150, Macro.job_queue_latency(:default, **SCHEDULE), LATENCY_DELTA
    end

    assert_equal [0], reads("schedule")
  end

  def test_a_size_after_a_latency_that_stopped_early_reads_the_rest_and_counts_everything
    plant("schedule", queue: "mailer", age: 300)
    3.times { plant("schedule", queue: "default", age: 100) }
    plant("schedule", queue: "mailer", age: 50)

    with_batch(2) do
      assert_in_delta 300, Macro.job_queue_latency(:mailer, **SCHEDULE), LATENCY_DELTA
      assert_equal [0], reads("schedule")

      assert_equal 3, Macro.job_queue_size(:default, **SCHEDULE_SIZE)
      assert_equal 2, Macro.job_queue_size(:mailer, **SCHEDULE_SIZE)
    end

    assert_equal [0, 1, 3, 5], reads("schedule")
  end

  def test_a_finished_walk_serves_every_later_size_of_the_round_without_a_read
    2.times { plant("schedule", queue: "default", age: 100) }
    plant("schedule", queue: "mailer", age: 50)

    assert_equal 2, Macro.job_queue_size(:default, **SCHEDULE_SIZE)
    finished = reads("schedule")

    assert_equal 1, Macro.job_queue_size(:mailer, **SCHEDULE_SIZE)
    assert_equal 3, Macro.job_queue_size(:default, :mailer, **SCHEDULE_SIZE)
    assert_equal 0, Macro.job_queue_size(:other, **SCHEDULE_SIZE)
    assert_in_delta 50, Macro.job_queue_latency(:mailer, **SCHEDULE), LATENCY_DELTA
    assert_in_delta 100, Macro.job_queue_latency(:default, :mailer, **SCHEDULE), LATENCY_DELTA
    assert_equal finished, reads("schedule")
  end

  def test_the_end_of_a_round_forgets_the_walk_and_the_next_round_starts_at_the_first_member
    plant("schedule", queue: "default", age: 100)
    assert_equal 1, Macro.job_queue_size(:default, **SCHEDULE_SIZE)
    assert Cache.end_sample!(@round)

    plant("schedule", queue: "default", age: 90)
    Cache.begin_sample!
    ZrangeLog::CALLS.clear

    assert_equal 2, Macro.job_queue_size(:default, **SCHEDULE_SIZE)
    assert_equal 0, reads("schedule").first
  end

  def test_a_new_round_does_not_inherit_the_walk_of_a_round_that_was_never_ended
    plant("schedule", queue: "default", age: 100)
    assert_equal 1, Macro.job_queue_size(:default, **SCHEDULE_SIZE)

    plant("schedule", queue: "default", age: 90)
    Cache.begin_sample!

    assert_equal 2, Macro.job_queue_size(:default, **SCHEDULE_SIZE)
  end

  def test_outside_a_round_every_call_walks_the_set_itself
    Cache.end_sample!
    plant("schedule", queue: "default", age: 100)

    assert_equal 1, Macro.job_queue_size(:default, **SCHEDULE_SIZE)
    plant("schedule", queue: "default", age: 90)
    assert_equal 2, Macro.job_queue_size(:default, **SCHEDULE_SIZE)

    assert_equal [0, 0], reads("schedule").select(&:zero?)
  end

  def test_an_ended_round_is_not_ended_again_by_its_old_token_once_a_new_round_runs
    plant("schedule", queue: "default", age: 100)
    current = Cache.begin_sample!
    assert_equal 1, Macro.job_queue_size(:default, **SCHEDULE_SIZE)
    ZrangeLog::CALLS.clear

    refute Cache.end_sample!(@round)
    assert_equal 1, Macro.job_queue_size(:default, **SCHEDULE_SIZE)
    assert_empty reads("schedule")

    assert Cache.end_sample!(current)
    assert Cache.end_sample!
  end

  def test_the_due_moment_of_a_round_is_fixed_when_the_set_is_first_read
    plant("schedule", queue: "default", age: 100)
    plant("schedule", queue: "default", age: -30)

    assert_equal 1, Macro.job_queue_size(:default, **SCHEDULE_SIZE)
    Timecop.freeze(Time.now + 60) do
      assert_equal 1, Macro.job_queue_size(:default, **SCHEDULE_SIZE)
      Cache.end_sample!
      assert_equal 2, Macro.job_queue_size(:default, **SCHEDULE_SIZE)
    end
  end

  def test_a_job_due_at_this_very_moment_counts_and_a_later_one_does_not
    Timecop.freeze(Time.at(1_800_000_000)) do
      plant("schedule", queue: "default", at: 1_800_000_000.0)
      plant("schedule", queue: "default", at: 1_800_000_000.5)
      Cache.begin_sample!

      assert_equal 1, Macro.job_queue_size(:default, **SCHEDULE_SIZE)
      assert_equal 0.0, Macro.job_queue_latency(:default, **SCHEDULE)
    end
  end

  def test_a_set_that_is_empty_or_holds_only_future_jobs_counts_zero_for_every_queue
    assert_equal 0, Macro.job_queue_size(:default, **SCHEDULE_SIZE)
    assert_equal 0.0, Macro.job_queue_latency(:default, **SCHEDULE)

    Cache.begin_sample!
    plant("schedule", queue: "default", age: -60)
    plant("retry", queue: "default", age: -60)

    assert_equal 0, Macro.job_queue_size(:default, skip_working: true)
    assert_equal 0.0, Macro.job_queue_latency(:default)
  end

  def test_the_retry_set_is_walked_the_same_way_and_on_its_own
    plant("retry", queue: "mailer", age: 300)
    plant("retry", queue: "default", age: 100)
    plant("schedule", queue: "default", age: 40)

    assert_in_delta 300, Macro.job_queue_latency(:mailer, skip_scheduled: true), LATENCY_DELTA
    assert_in_delta 100, Macro.job_queue_latency(:default, skip_scheduled: true), LATENCY_DELTA
    assert_equal 1, Macro.job_queue_size(:default, **RETRY_SIZE)

    assert_equal [0, 1, 2], reads("retry")
    assert_empty reads("schedule")
  end

  def test_a_latency_without_skips_reads_both_sets_and_a_second_call_reads_neither
    plant("schedule", queue: "default", age: 100)
    plant("retry", queue: "default", age: 200)

    assert_in_delta 200, Macro.job_queue_latency(:default), LATENCY_DELTA
    first = ZrangeLog::CALLS.dup
    assert_in_delta 200, Macro.job_queue_latency(:default), LATENCY_DELTA

    assert_equal [["retry", 0], ["schedule", 0]], first.sort
    assert_equal first, ZrangeLog::CALLS
  end

  def test_a_skipped_set_is_not_read
    plant("schedule", queue: "default", age: 100)
    plant("retry", queue: "default", age: 200)

    assert_equal 1, Macro.job_queue_size(:default, skip_retries: true, skip_working: true)
    assert_equal 1, Macro.job_queue_size(:default, skip_scheduled: true, skip_working: true)
    assert_equal 0, Macro.job_queue_size(:default, skip_scheduled: true, skip_retries: true, skip_working: true)
    assert_equal [["retry", 0], ["retry", 1], ["schedule", 0], ["schedule", 1]], ZrangeLog::CALLS.sort
  end

  def test_the_scheduled_cap_stops_the_walk_at_that_many_matches_and_a_later_call_reads_on
    6.times { |index| plant("schedule", queue: "default", age: 100 - index) }
    plant("schedule", queue: "mailer", age: 10)

    with_batch(2) do
      assert_equal 3, Macro.job_queue_size(:default, max_scheduled: 3, **SCHEDULE_SIZE)
      assert_equal [0, 2], reads("schedule")

      assert_equal 6, Macro.job_queue_size(:default, **SCHEDULE_SIZE)
      assert_equal 1, Macro.job_queue_size(:mailer, max_scheduled: 5, **SCHEDULE_SIZE)
      assert_equal 3, Macro.job_queue_size(:default, max_scheduled: 3, **SCHEDULE_SIZE)
    end

    assert_equal [0, 2, 3, 5, 7], reads("schedule")
  end

  def test_the_scheduled_cap_counts_matches_of_the_named_queues_only
    4.times { |index| plant("schedule", queue: "mailer", age: 100 - index) }
    2.times { |index| plant("schedule", queue: "default", age: 50 - index) }

    assert_equal 2, Macro.job_queue_size(:default, max_scheduled: 2, **SCHEDULE_SIZE)
    assert_equal 4, Macro.job_queue_size(:mailer, **SCHEDULE_SIZE)
  end

  def test_a_scheduled_cap_of_zero_counts_nothing_and_reads_nothing
    plant("schedule", queue: "default", age: 100)

    assert_equal 0, Macro.job_queue_size(:default, max_scheduled: 0, **SCHEDULE_SIZE)
    assert_equal 0, Macro.job_queue_size(:default, max_scheduled: -4, **SCHEDULE_SIZE)

    assert_empty reads("schedule")
  end

  def test_the_scheduled_cap_does_not_limit_the_retry_set
    3.times { |index| plant("schedule", queue: "default", age: 100 - index) }
    3.times { |index| plant("retry", queue: "default", age: 100 - index) }

    assert_equal 4, Macro.job_queue_size(:default, max_scheduled: 1, skip_working: true)
  end

  def test_no_queue_names_counts_every_due_member_with_one_count_and_no_walk
    3.times { plant("schedule", queue: "default", age: 100) }
    plant("schedule", queue: "mailer", age: 40)
    plant("schedule", queue: "default", age: -60)
    plant_raw("schedule", "not-json", age: 200)
    2.times { plant("retry", queue: "default", age: 100) }

    assert_equal 5, Macro.job_queue_size(**SCHEDULE_SIZE)
    assert_equal 5, Macro.job_queue_size(max_scheduled: 2, **SCHEDULE_SIZE)
    assert_equal 2, Macro.job_queue_size(**RETRY_SIZE)
    assert_empty ZrangeLog::CALLS

    assert_equal 4, Macro.job_queue_size(:default, :mailer, **SCHEDULE_SIZE)
  end

  def test_no_queue_names_reads_the_first_member_for_the_latency_and_nothing_more
    plant("schedule", queue: "default", age: 100)
    plant("schedule", queue: "mailer", age: 40)
    plant("retry", queue: "default", age: 250)

    assert_in_delta 100, Macro.job_queue_latency(**SCHEDULE), LATENCY_DELTA
    assert_in_delta 250, Macro.job_queue_latency, LATENCY_DELTA

    assert_equal [["schedule", 0, 0], ["retry", 0, 0], ["schedule", 0, 0]].sort, ZrangeLog::RANGES.sort
  end

  def test_no_queue_names_and_no_due_job_is_a_latency_of_zero
    assert_equal 0.0, Macro.job_queue_latency

    plant("schedule", queue: "default", age: -60)
    plant("retry", queue: "default", age: -60)

    assert_equal 0.0, Macro.job_queue_latency
    assert_equal 0, Macro.job_queue_size(skip_working: true)
  end

  def test_a_member_that_is_not_a_job_with_a_queue_is_skipped_and_the_walk_goes_on
    ["not-json", "null", "[1]", "true", '{"class":"SampleWorker"}', '{"queue":null}', '{"queue":""}'].each_with_index do |member, index|
      plant_raw("schedule", member, age: 300 - index)
      plant_raw("retry", member, age: 300 - index)
    end
    plant("schedule", queue: "default", age: 100)
    plant("retry", queue: "default", age: 80)

    assert_equal 2, Macro.job_queue_size(:default, skip_working: true)
    assert_in_delta 100, Macro.job_queue_latency(:default), LATENCY_DELTA
  end

  def test_members_with_the_same_score_are_each_counted_once_across_batches
    Timecop.freeze(Time.now) do
      5.times { plant("schedule", queue: "default", age: 100) }
      3.times { plant("schedule", queue: "mailer", age: 100) }
      Cache.begin_sample!

      with_batch(3) do
        assert_in_delta 100, Macro.job_queue_latency(:mailer, **SCHEDULE), LATENCY_DELTA
        assert_equal 5, Macro.job_queue_size(:default, **SCHEDULE_SIZE)
        assert_equal 3, Macro.job_queue_size(:mailer, **SCHEDULE_SIZE)
      end
    end
  end

  def test_a_set_longer_than_one_batch_is_read_batch_by_batch
    assert_equal 1_000, Cache::BATCH
    7.times { |index| plant("schedule", queue: "default", age: 100 - index) }

    with_batch(3) { assert_equal 7, Macro.job_queue_size(:default, **SCHEDULE_SIZE) }

    assert_equal [0, 3, 6, 7], reads("schedule")
  end

  def test_the_live_queue_is_read_on_every_call_of_a_round
    plant("schedule", queue: "default", age: 100)
    assert_equal 1, Macro.job_queue_size(:default, skip_retries: true, skip_working: true)

    Sidekiq::Client.push("queue" => "default", "class" => SampleWorker, "args" => [])

    assert_equal 2, Macro.job_queue_size(:default, skip_retries: true, skip_working: true)
    assert_equal [0, 1], reads("schedule")
  end

  def test_the_server_script_neither_fills_nor_reads_the_walk_of_a_round
    plant("schedule", queue: "default", age: 100)

    assert_equal 1, Macro.job_queue_size(:default, server: true, **SCHEDULE_SIZE)
    assert_empty reads("schedule")

    assert_equal 1, Macro.job_queue_size(:default, **SCHEDULE_SIZE)
    plant("schedule", queue: "default", age: 90)

    assert_equal 2, Macro.job_queue_size(:default, server: true, **SCHEDULE_SIZE)
    assert_equal 1, Macro.job_queue_size(:default, **SCHEDULE_SIZE)
  end

  def test_two_threads_that_ask_at_once_get_the_same_count_and_the_set_is_read_once
    5.times { |index| plant("schedule", queue: "default", age: 100 - index) }
    gate = Queue.new

    counts = Array.new(4) do
      Thread.new do
        gate.pop
        Macro.job_queue_size(:default, **SCHEDULE_SIZE)
      end
    end
    4.times { gate << true }

    assert_equal [5, 5, 5, 5], counts.map(&:value)
    assert_equal [0, 5], reads("schedule")
  end

  def test_a_set_whose_first_member_is_not_due_has_no_latency
    plant("schedule", queue: "default", age: -60)

    assert_equal 0.0, Cache.latency("schedule", Set.new)
  end

  def test_a_new_round_reads_the_running_jobs_again
    Sidekiq::Workers.any_instance.expects(:each).twice

    Macro.job_queue_working(:default)
    Cache.begin_sample!
    Macro.job_queue_working(:default)
  end

  def test_the_running_jobs_are_read_once_in_a_round
    Sidekiq::Workers.any_instance.expects(:each).once

    3.times { assert_equal 0, Macro.job_queue_working(:default) }
  end

  def test_the_running_jobs_are_read_on_every_call_outside_a_round
    Cache.end_sample!
    Sidekiq::Workers.any_instance.expects(:each).twice

    2.times { assert_equal 0, Macro.job_queue_working(:default) }
  end

  def test_a_fork_reset_forgets_the_round_and_works_when_the_lock_was_held
    plant("schedule", queue: "default", age: 100)
    assert_equal 1, Macro.job_queue_size(:default, **SCHEDULE_SIZE)
    holder = Thread.new { Cache.instance_variable_get(:@mutex).synchronize { sleep } }
    sleep(0.01) until holder.status == "sleep"

    Macro.reinit_after_fork
    plant("schedule", queue: "default", age: 90)

    assert_equal 2, Macro.job_queue_size(:default, **SCHEDULE_SIZE)
    assert_equal 2, Macro.job_queue_size(:default, **SCHEDULE_SIZE)
    assert_equal [0, 0], reads("schedule").select(&:zero?).last(2)
  ensure
    holder&.kill
  end

  def test_the_fork_reset_of_the_dispatcher_reaches_the_due_cache
    plant("schedule", queue: "default", age: 100)
    assert_equal 1, Macro.job_queue_size(:default, **SCHEDULE_SIZE)
    plant("schedule", queue: "default", age: 90)

    HireFire.configuration.dispatcher.abandon_inherited_state!

    assert_equal 2, Macro.job_queue_size(:default, **SCHEDULE_SIZE)
  end

  def test_the_round_hooks_of_the_macro_open_a_round_and_close_it
    Cache.end_sample!
    plant("schedule", queue: "default", age: 100)

    token = Macro.before_sample_job_queues
    assert_equal 1, Macro.job_queue_size(:default, **SCHEDULE_SIZE)
    plant("schedule", queue: "default", age: 90)
    assert_equal 1, Macro.job_queue_size(:default, **SCHEDULE_SIZE)

    Macro.after_sample_job_queues(token)
    assert_equal 2, Macro.job_queue_size(:default, **SCHEDULE_SIZE)
  end

  def test_a_sample_round_of_the_sampler_reads_a_set_once_for_all_its_entries
    Cache.end_sample!
    plant("schedule", queue: "mailer", age: 300)
    plant("schedule", queue: "default", age: 100)
    ZrangeLog::CALLS.clear

    sample_plan(
      {"name" => "mailer", "adapter" => "sidekiq", "strategy" => "jql", "queues" => ["mailer"], "options" => {"skip_retries" => true}},
      {"name" => "default", "adapter" => "sidekiq", "strategy" => "jql", "queues" => ["default"], "options" => {"skip_retries" => true}}
    )

    assert_equal [0, 1], reads("schedule")
    data = HireFire.configuration.buffer.flush
    assert_in_delta 300, data["mailer"]["jql"].values.first, LATENCY_DELTA
    assert_in_delta 100, data["default"]["jql"].values.first, LATENCY_DELTA
  end

  def test_a_sample_round_of_the_sampler_ends_when_an_entry_raises_any_exception
    Cache.end_sample!
    plant("schedule", queue: "default", age: 100)
    Macro.stubs(:job_queue_size).raises(Exception, "sampler boom")

    assert_raises(Exception) do
      sample_plan("name" => "worker", "adapter" => "sidekiq", "strategy" => "jqs", "queues" => ["default"])
    end
    Macro.unstub(:job_queue_size)
    assert_equal 1, Macro.job_queue_size(:default, **SCHEDULE_SIZE)
    plant("schedule", queue: "default", age: 90)

    assert_equal 2, Macro.job_queue_size(:default, **SCHEDULE_SIZE)
  end

  private

  def reads(set_name)
    ZrangeLog::CALLS.select { |key, _start| key == set_name }.map(&:last)
  end

  def with_batch(size)
    original = Cache::BATCH
    Cache.send(:remove_const, :BATCH)
    Cache.const_set(:BATCH, size)
    yield
  ensure
    Cache.send(:remove_const, :BATCH)
    Cache.const_set(:BATCH, original)
  end

  def plant(set_name, queue:, age: nil, at: nil)
    member = Sidekiq.dump_json("queue" => queue, "class" => "SampleWorker", "args" => [], "jid" => SecureRandom.hex(12), "enqueued_at" => Time.now.to_f)
    plant_raw(set_name, member, age: age, at: at)
  end

  def plant_raw(set_name, member, age: nil, at: nil)
    Sidekiq.redis { |connection| connection.call("zadd", set_name, at || Time.now.to_f - age, member) }
  end
end
