# frozen_string_literal: true

require_relative "../../test/hirefire/macro/test_good_job"

class GoodJobInterruptedEvidence < HireFire::Macro::GoodJobTest
  def test_evidence_a_job_whose_worker_died_counts_as_waiting
    job_id = BasicJob.perform_later.job_id
    good_job_class.where(active_job_id: job_id).update_all(performed_at: 5.minutes.ago, finished_at: nil)

    runnable = good_job_class.where(finished_at: nil)
    runnable = runnable.where(locked_by_id: nil) if good_job_class.column_names.include?("locked_by_id")
    assert_equal 1, runnable.count, "Good Job itself would run this job again"
    assert_equal 1, HireFire::Macro::GoodJob.job_queue_size(skip_working: true)
  end
end
