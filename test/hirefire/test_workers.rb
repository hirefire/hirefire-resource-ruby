# frozen_string_literal: true

require "test_helper"

class HireFire::WorkersTest < Minitest::Test
  def buffer
    HireFire.configuration.buffer
  end

  def test_sample
    HireFire.configure do |config|
      config.dyno(:worker) { 42 }
      config.dyno(:mailer) { 18 }
    end

    HireFire.configuration.workers.sample

    data = buffer.flush
    assert_equal [
      {"name" => "worker", "sample" => 42},
      {"name" => "mailer", "sample" => 18}
    ], data[:workers]
  end

  def test_latest_sample_wins_across_multiple_samples
    values = [5, 9].each
    HireFire.configure do |config|
      config.dyno(:worker) { values.next }
    end

    HireFire.configuration.workers.sample
    HireFire.configuration.workers.sample

    data = buffer.flush
    assert_equal [{"name" => "worker", "sample" => 9}], data[:workers]
  end

  def test_raising_sampler_is_isolated_and_logged
    log = StringIO.new
    HireFire.configure do |config|
      config.dyno(:worker) { raise "Redis down" }
      config.dyno(:mailer) { 18 }
    end
    HireFire.configuration.logger = Logger.new(log)

    HireFire.configuration.workers.sample

    data = buffer.flush
    assert_equal [{"name" => "mailer", "sample" => 18}], data[:workers]
    assert_includes log.string, "Redis down"
  end

  def test_invalid_sample_values_are_dropped_and_logged
    log = StringIO.new
    values = ["10", nil, -1, Float::INFINITY, Float::NAN, 7].each
    HireFire.configure do |config|
      config.dyno(:worker) { values.next }
    end
    HireFire.configuration.logger = Logger.new(log)

    5.times { HireFire.configuration.workers.sample }
    assert_empty buffer.flush[:workers]
    assert_includes log.string, "expected a non-negative number"

    HireFire.configuration.workers.sample
    assert_equal [{"name" => "worker", "sample" => 7}], buffer.flush[:workers]
  end

  def test_enumerable
    workers = HireFire::Workers.new
    workers << HireFire::Worker.new(:worker) { 1 }
    workers << HireFire::Worker.new(:mailer) { 2 }

    assert_equal ["worker", "mailer"], workers.map(&:name)
  end

  def test_any_and_count
    workers = HireFire::Workers.new
    refute workers.any?
    assert_equal 0, workers.count

    workers << HireFire::Worker.new(:worker) { 1 }
    assert workers.any?
    assert_equal 1, workers.count
  end

  def test_zero_sample_is_accepted
    HireFire.configure do |config|
      config.dyno(:worker) { 0 }
    end

    HireFire.configuration.workers.sample

    # 0 is a valid idle-queue reading, not a sampler failure.
    assert_equal [{"name" => "worker", "sample" => 0}], buffer.flush[:workers]
  end
end
