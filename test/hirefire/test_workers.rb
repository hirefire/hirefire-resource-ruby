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

  def test_accumulates_across_multiple_samples
    HireFire.configure do |config|
      config.dyno(:worker) { 5 }
    end

    HireFire.configuration.workers.sample
    HireFire.configuration.workers.sample

    data = buffer.flush
    assert_equal 2, data[:workers].size
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
end
