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
