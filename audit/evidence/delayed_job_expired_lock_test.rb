# frozen_string_literal: true

require_relative "../../test/hirefire/macro/test_delayed_job"

class DelayedJobExpiredLockEvidence < HireFire::Macro::Delayed::JobTest
  def test_evidence_a_job_locked_longer_than_max_run_time_counts_as_waiting
    skip "ActiveRecord only" unless defined?(ActiveRecord)

    expired = Delayed::Worker.max_run_time + 1.hour
    BasicJob.delay(queue: :default).perform.update(locked_at: expired.ago, locked_by: "a worker that was killed")

    ready = Delayed::Job.ready_to_run("another worker", Delayed::Worker.max_run_time).count
    assert_equal 1, ready, "Delayed Job itself would run this job again"
    assert_equal 0, HireFire::Macro::Delayed::Job.job_queue_working(:default)
    assert_equal 1, HireFire::Macro::Delayed::Job.job_queue_size(:default, skip_working: true)
  end
end
