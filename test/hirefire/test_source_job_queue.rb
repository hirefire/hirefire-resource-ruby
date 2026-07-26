# frozen_string_literal: true

require "test_helper"

class HireFire::Source::JobQueueTest < Minitest::Test
  def test_name
    job_queue = HireFire::Source::JobQueue.new(:worker) { 1 + 1 }
    assert_equal "worker", job_queue.name
  end

  def test_sample_returns_the_sampler_result
    job_queue = HireFire::Source::JobQueue.new("worker") { 1 }
    assert_equal 1, job_queue.sample
  end
end
