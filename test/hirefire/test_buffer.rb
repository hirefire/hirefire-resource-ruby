# frozen_string_literal: true

require "test_helper"

class HireFire::BufferTest < Minitest::Test
  def buffer
    @buffer ||= HireFire::Buffer.new
  end

  def test_sample_rqt_accumulates_sum_and_count
    Timecop.freeze Time.at(100) do
      buffer.sample("web", "rqt", 10)
      buffer.sample("web", "rqt", 20)
      buffer.sample("web", "rqt", 30)
    end

    data = buffer.flush
    assert_equal({sum: 60.0, count: 3}, data["web"]["rqt"][100])
  end

  def test_discard_inherited_clears_all_strategies
    Timecop.freeze Time.at(100) do
      buffer.sample("web", "rqt", 7)
      buffer.sample("worker", "jql", 5)
      buffer.sample("web", "cpu", 12.5)

      buffer.discard_inherited

      assert_empty buffer.flush
    end
  end

  def test_rqt_caps_count_at_sample_count_limit
    Timecop.freeze Time.at(100) do
      series = buffer.send(:series_for, "web", "rqt")
      series[100] = {sum: 0.0, count: HireFire::Buffer::SAMPLE_COUNT_LIMIT}
      buffer.sample("web", "rqt", 1)

      data = buffer.flush
      bucket = data["web"]["rqt"][100]
      assert_equal HireFire::Buffer::SAMPLE_COUNT_LIMIT, bucket[:count]
      assert_in_delta 0.0, bucket[:sum], 0.0001
    end
  end

  def test_sample_ignores_non_finite_and_non_numeric
    Timecop.freeze Time.at(100) do
      buffer.sample("web", "rqt", Float::NAN)
      buffer.sample("web", "rqt", Float::INFINITY)
      buffer.sample("web", "cpu", "nope")
      buffer.sample("web", "rqt", 5)

      data = buffer.flush
      assert_equal({sum: 5.0, count: 1}, data["web"]["rqt"][100])
      assert_nil data.dig("web", "cpu")
    end
  end

  def test_reinit_after_fork_clears_metrics_and_replaces_mutex
    Timecop.freeze Time.at(100) do
      buffer.sample("web", "rqt", 7)
      old_mutex = buffer.instance_variable_get(:@mutex)

      buffer.reinit_after_fork

      refute_same old_mutex, buffer.instance_variable_get(:@mutex)
      assert_empty buffer.flush
    end
  end

  def test_repopulate_rejects_non_rqt_strategy
    Timecop.freeze Time.at(100) do
      buffer.repopulate("web", "cpu", {100 => {sum: 1.0, count: 1}})
      assert_empty buffer.flush
    end
  end

  def test_non_rqt_latest_wins_bare_scalar
    Timecop.freeze Time.at(100) do
      buffer.sample("worker", "jqs", 1)
      buffer.sample("worker", "jqs", 99)
      buffer.sample("web", "cpu", 10.0)
      buffer.sample("web", "cpu", 37.5)

      data = buffer.flush
      assert_equal 99, data["worker"]["jqs"][100]
      assert_equal 37.5, data["web"]["cpu"][100]
    end
  end

  def test_non_rqt_latest_wins_without_replace_kwarg
    Timecop.freeze Time.at(100) do
      buffer.sample("worker", "jqs", 1)
      buffer.sample("worker", "jqs", 99)

      data = buffer.flush
      assert_equal 99, data["worker"]["jqs"][100]
    end
  end

  def test_sample_rqt_groups_by_timestamp
    Timecop.freeze Time.at(100) do
      buffer.sample("web", "rqt", 12)
    end

    Timecop.freeze Time.at(101) do
      buffer.sample("web", "rqt", 8)
    end

    data = buffer.flush
    assert_equal({100 => {sum: 12.0, count: 1}, 101 => {sum: 8.0, count: 1}}, data["web"]["rqt"])
  end

  def test_sample_job_strategies
    buffer.sample("worker", "jql", 42)
    buffer.sample("mailer", "jqs", 18)

    data = buffer.flush
    assert_equal 42, data["worker"]["jql"].values.first
    assert_equal 18, data["mailer"]["jqs"].values.first
  end

  def test_flush_returns_and_resets
    Timecop.freeze Time.at(100) do
      buffer.sample("web", "rqt", 5)
      buffer.sample("worker", "jql", 10)
    end

    data = buffer.flush
    assert_equal({100 => {sum: 5.0, count: 1}}, data["web"]["rqt"])
    assert_equal({100 => 10}, data["worker"]["jql"])

    data = buffer.flush
    assert_empty data
  end

  def test_multi_strategy_under_one_name
    Timecop.freeze Time.at(100) do
      buffer.sample("web", "rqt", 12)
      buffer.sample("web", "cpu", 37.5)
    end

    data = buffer.flush
    assert_equal({100 => {sum: 12.0, count: 1}}, data["web"]["rqt"])
    assert_equal({100 => 37.5}, data["web"]["cpu"])
  end

  def test_sample_rqt_bounded_when_dispatch_is_starved
    (1000..1070).each do |second|
      Timecop.freeze(Time.at(second)) { buffer.sample("web", "rqt", 1) }
    end

    data = buffer.flush
    assert_operator data["web"]["rqt"].size, :<=, 66
    assert_equal 1006, data["web"]["rqt"].keys.min
    assert_equal 1070, data["web"]["rqt"].keys.max
  end

  def test_sample_cpu_bounded_when_dispatch_is_starved
    (1000..1070).each do |second|
      Timecop.freeze(Time.at(second)) { buffer.sample("clock", "cpu", 50.0) }
    end

    data = buffer.flush
    assert_operator data["clock"]["cpu"].size, :<=, 66
    assert_equal 1070, data["clock"]["cpu"].keys.max
  end

  def test_repopulate_rqt_within_ttl
    Timecop.freeze Time.at(100) do
      buffer.repopulate("web", "rqt", {
        90 => {sum: 5.0, count: 1},
        30 => {sum: 10.0, count: 1}
      })
    end

    data = buffer.flush
    assert_equal({90 => {sum: 5.0, count: 1}}, data["web"]["rqt"])
    refute data["web"]["rqt"].key?(30)
  end

  def test_vector_c_repopulate_merge_sum_and_count
    Timecop.freeze Time.at(100) do
      buffer.repopulate("web", "rqt", {100 => {sum: 10.0, count: 1}})
      buffer.sample("web", "rqt", 15)
      buffer.sample("web", "rqt", 15)
    end

    assert_equal({sum: 40.0, count: 3}, buffer.flush["web"]["rqt"][100])
  end

  def test_repopulate_accepts_string_keys
    Timecop.freeze Time.at(100) do
      buffer.repopulate("web", "rqt", {100 => {"sum" => 5.0, "count" => 1}})
    end

    assert_equal({sum: 5.0, count: 1}, buffer.flush["web"]["rqt"][100])
  end

  def test_repopulate_clamps_to_sample_count_limit
    Timecop.freeze Time.at(100) do
      limit = HireFire::Buffer::SAMPLE_COUNT_LIMIT
      buffer.repopulate("web", "rqt", {100 => {sum: limit.to_f, count: limit}})
      buffer.repopulate("web", "rqt", {100 => {sum: 100.0, count: 100}})
      bucket = buffer.flush["web"]["rqt"][100]
      assert_equal limit, bucket[:count]
      assert_in_delta 1.0, bucket[:sum] / bucket[:count], 0.001
    end
  end

  def test_repopulate_rqt_keeps_the_second_exactly_at_the_ttl_boundary
    Timecop.freeze Time.at(100) do
      buffer.repopulate("web", "rqt", {40 => {sum: 5.0, count: 1}})
    end

    assert_equal({40 => {sum: 5.0, count: 1}}, buffer.flush["web"]["rqt"])
  end

  def test_custom_ttl_is_honored_by_repopulate
    custom = HireFire::Buffer.new(ttl: 10)
    Timecop.freeze Time.at(100) do
      custom.repopulate("web", "rqt", {
        95 => {sum: 1.0, count: 1},
        80 => {sum: 2.0, count: 1}
      })
    end

    data = custom.flush
    assert_equal({95 => {sum: 1.0, count: 1}}, data["web"]["rqt"])
    refute data["web"]["rqt"].key?(80)
  end

  def test_sample_coerces_symbol_strategy_to_string
    Timecop.freeze Time.at(100) do
      buffer.sample("web", :rqt, 3)
    end

    assert_equal({100 => {sum: 3.0, count: 1}}, buffer.flush["web"]["rqt"])
  end

  def test_concurrent_sample_flush_and_repopulate
    errors = []
    mutex = Mutex.new

    threads = 8.times.map do |i|
      Thread.new do
        80.times do |j|
          buffer.sample("web", "rqt", j)
          buffer.sample("worker", "jql", j) if j.even?
          buffer.repopulate("web", "rqt", {Time.now.to_i => {sum: i.to_f, count: 1}}) if (j % 10).zero?
          buffer.flush if (j % 17).zero?
        end
      rescue => e
        mutex.synchronize { errors << e }
      end
    end
    threads.each(&:join)

    assert_empty errors, errors.map(&:message).join(", ")
    data = buffer.flush
    assert_kind_of Hash, data
  end

  def test_repopulate_skips_non_hash_and_non_positive_count
    Timecop.freeze Time.at(200) do
      buffer.repopulate("web", "rqt", {
        190 => 12,
        191 => {sum: 5.0, count: 0},
        192 => {sum: 7.0, count: -1},
        193 => {sum: 9.0, count: 1}
      })
    end

    assert_equal({193 => {sum: 9.0, count: 1}}, buffer.flush["web"]["rqt"])
  end
end
