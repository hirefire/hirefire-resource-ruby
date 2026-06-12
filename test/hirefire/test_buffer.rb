# frozen_string_literal: true

require "test_helper"

class HireFire::BufferTest < Minitest::Test
  def buffer
    @buffer ||= HireFire::Buffer.new
  end

  def test_sample_web
    Timecop.freeze Time.at(100) do
      buffer.sample_web(12)
      buffer.sample_web(8)
    end

    data = buffer.flush
    assert_equal({100 => [12, 8]}, data[:web])
  end

  def test_sample_web_groups_by_timestamp
    Timecop.freeze Time.at(100) do
      buffer.sample_web(12)
    end

    Timecop.freeze Time.at(101) do
      buffer.sample_web(8)
    end

    data = buffer.flush
    assert_equal({100 => [12], 101 => [8]}, data[:web])
  end

  def test_sample_worker
    buffer.sample_worker("worker", 42)
    buffer.sample_worker("mailer", 18)

    data = buffer.flush
    assert_equal [
      {"name" => "worker", "sample" => 42},
      {"name" => "mailer", "sample" => 18}
    ], data[:workers]
  end

  def test_flush_returns_both_and_resets
    Timecop.freeze Time.at(100) do
      buffer.sample_web(5)
    end

    buffer.sample_worker("worker", 10)

    data = buffer.flush
    assert_equal({100 => [5]}, data[:web])
    assert_equal [{"name" => "worker", "sample" => 10}], data[:workers]

    data = buffer.flush
    assert_empty data[:web]
    assert_empty data[:workers]
  end

  def test_sample_worker_latest_wins_per_name
    buffer.sample_worker("worker", 42)
    buffer.sample_worker("mailer", 18)
    buffer.sample_worker("worker", 7)

    data = buffer.flush
    assert_equal [
      {"name" => "mailer", "sample" => 18},
      {"name" => "worker", "sample" => 7}
    ], data[:workers]
  end

  def test_sample_web_bounded_when_dispatch_is_starved
    (1000..1070).each do |second|
      Timecop.freeze(Time.at(second)) { buffer.sample_web(1) }
    end

    data = buffer.flush
    assert_operator data[:web].size, :<=, 66
    assert_equal 1006, data[:web].keys.min # seconds beyond the TTL pruned
    assert_equal 1070, data[:web].keys.max
  end

  def test_sample_cpu_bounded_when_dispatch_is_starved
    (1000..1070).each do |second|
      Timecop.freeze(Time.at(second)) { buffer.sample_cpu("clock", 50.0) }
    end

    data = buffer.flush
    assert_operator data[:cpu]["clock"].size, :<=, 66
    assert_equal 1070, data[:cpu]["clock"].keys.max
  end

  def test_repopulate_web_within_ttl
    Timecop.freeze Time.at(100) do
      buffer.repopulate_web({90 => [5], 30 => [10]})
    end

    data = buffer.flush
    assert_equal({90 => [5]}, data[:web])
    refute data[:web].key?(30)
  end

  def test_repopulate_web_merges_with_existing
    Timecop.freeze Time.at(100) do
      buffer.sample_web(1)
    end

    Timecop.freeze Time.at(100) do
      buffer.repopulate_web({100 => [2, 3]})
    end

    data = buffer.flush
    assert_equal [1, 2, 3], data[:web][100]
  end
end
