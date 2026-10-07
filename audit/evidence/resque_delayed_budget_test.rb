# frozen_string_literal: true

require_relative "../../test/hirefire/macro/test_resque"

class ResqueDelayedBudgetEvidence < HireFire::Macro::ResqueTest
  def test_evidence_size_without_queue_names_survives_a_large_due_backlog
    timestamp = Time.now.to_i - 60
    payload = JSON.generate("class" => "BasicJob", "args" => [], "queue" => "default")
    Resque.redis.zadd("delayed_queue_schedule", timestamp, timestamp)
    50.times { Resque.redis.rpush("delayed:#{timestamp}", [payload] * 1_000) }

    assert_equal 50_000, HireFire::Macro::Resque.job_queue_size(skip_working: true)
  end
end
