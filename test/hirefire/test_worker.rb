# frozen_string_literal: true

require "test_helper"

class HireFire::WorkerTest < Minitest::Test
  def test_name_and_sample
    worker = HireFire::Worker.new(:worker) { 1 + 1 }
    assert_equal "worker", worker.name
    assert_equal 2, worker.sample
  end

  def test_name_normalized_to_string
    worker = HireFire::Worker.new("worker") { 1 }
    assert_equal "worker", worker.name
  end
end
