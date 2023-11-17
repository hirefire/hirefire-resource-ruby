# frozen_string_literal: true

require "test_helper"

class HireFire::WorkerTest < Minitest::Test
  def test_setup_and_methods
    worker = HireFire::Worker.new(:worker) { 1 + 1 }
    assert_equal :worker, worker.name
    assert_equal 2, worker.call
  end

  def test_invalid_dyno_name_exception
    assert_raises(HireFire::Worker::InvalidDynoName) do
      HireFire::Worker.new("invalid name") { 1 + 1 }
    end
  end

  def test_missing_dyno_block_exception
    assert_raises(HireFire::Worker::MissingDynoBlock) do
      HireFire::Worker.new(:worker)
    end
  end
end
