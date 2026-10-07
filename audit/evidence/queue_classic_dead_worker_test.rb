# frozen_string_literal: true

require_relative "../../test/hirefire/macro/test_queue_classic"

class QueueClassicDeadWorkerEvidence < HireFire::Macro::QCTest
  def test_evidence_a_job_locked_by_a_dead_worker_counts_as_waiting
    QC.enqueue("BasicJob.perform")
    connection = ActiveRecord::Base.connection
    dead_pid = 2_000_000_000
    connection.execute("UPDATE #{QC.table_name} SET locked_at = now(), locked_by = #{dead_pid}")
    orphans = connection.select_value("SELECT COUNT(*) FROM #{QC.table_name} WHERE locked_by NOT IN (SELECT pid FROM pg_stat_activity)").to_i

    assert_equal 1, orphans, "Queue Classic unlocks this row when the next worker starts (QC.unlock_jobs_of_dead_workers)"
    assert_equal 0, HireFire::Macro::QC.job_queue_working
    assert_equal 1, HireFire::Macro::QC.job_queue_size(skip_working: true)
  end
end
