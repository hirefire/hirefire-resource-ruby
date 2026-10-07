# frozen_string_literal: true

require_relative "../../test/hirefire/macro/test_que"

class QuePgLocksEvidence < HireFire::Macro::QueTest
  def test_evidence_an_advisory_lock_in_another_database_is_not_a_running_job
    enqueue(job_options: {job_class: "BasicJob", queue: "default", run_at: Time.now - 60})
    id = Que.execute("SELECT id FROM que_jobs ORDER BY id DESC LIMIT 1").first.fetch(:id)
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    other = PG.connect(host: config[:host], port: config[:port], dbname: "postgres", user: config[:username], password: config[:password])
    other.exec_params("SELECT pg_advisory_lock($1)", [id])

    assert_equal 0, HireFire::Macro::Que.job_queue_working
    assert_equal 1, HireFire::Macro::Que.job_queue_size(skip_working: true)
  ensure
    other&.exec("SELECT pg_advisory_unlock_all()")
    other&.close
  end

  def test_evidence_a_two_key_advisory_lock_is_not_a_running_job
    enqueue(job_options: {job_class: "BasicJob", queue: "default", run_at: Time.now - 60})
    id = Que.execute("SELECT id FROM que_jobs ORDER BY id DESC LIMIT 1").first.fetch(:id)
    other = open_pg_connection
    other.exec_params("SELECT pg_advisory_lock(0, $1)", [id])

    assert_equal 0, HireFire::Macro::Que.job_queue_working
  ensure
    other&.exec("SELECT pg_advisory_unlock_all()")
    other&.close
  end
end
