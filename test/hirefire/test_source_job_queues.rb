# frozen_string_literal: true

require "test_helper"

class HireFire::Source::JobQueuesTest < Minitest::Test
  def buffer
    HireFire.configuration.buffer
  end

  def test_find_by_name_returns_nil_for_missing
    HireFire.configure { |config| config.dyno(:worker) { 1 } }
    assert_nil HireFire.configuration.job_queues.find_by_name("missing")
  end

  def test_find_by_name_is_case_insensitive_and_preserves_canonical_name
    HireFire.configure { |config| config.dyno(:Worker) { 1 } }
    found = HireFire.configuration.job_queues.find_by_name("worker")
    refute_nil found
    assert_equal "Worker", found.name
    assert_same found, HireFire.configuration.job_queues.find_by_name("WORKER")
  end

  def test_enumerable
    job_queues = HireFire::Source::JobQueues.new
    job_queues << HireFire::Source::JobQueue.new(:worker) { 1 }
    job_queues << HireFire::Source::JobQueue.new(:mailer) { 2 }

    assert_equal ["worker", "mailer"], job_queues.map(&:name)
  end

  def test_any_and_count
    job_queues = HireFire::Source::JobQueues.new
    refute job_queues.any?
    assert_equal 0, job_queues.count

    job_queues << HireFire::Source::JobQueue.new(:worker) { 1 }
    assert job_queues.any?
    assert_equal 1, job_queues.count
  end
end
