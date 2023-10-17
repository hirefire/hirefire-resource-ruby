# frozen_string_literal: true

require "test_helper"

class HireFire::WorkerTest < Minitest::Test
  def test_setup_and_methods
    worker = HireFire::Worker.new(:worker) { 1 + 1 }
    assert_equal :worker, worker.name
    assert_equal 2, worker.call
  end
end
