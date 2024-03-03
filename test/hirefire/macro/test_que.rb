# frozen_string_literal: true

require "test_helper"
require "que"

class HireFire::Macro::QueTest < Minitest::Test
  VERSION_QUE = Gem::Version.new(defined?(Que::Version) ? Que::Version : Que::VERSION)
  VERSION_1_0_0 = Gem::Version.new("1.0.0")
  VERSION_2_0_0 = Gem::Version.new("2.0.0")
  LATENCY_DELTA = 2

  if VERSION_QUE < VERSION_1_0_0
    require_relative "../../env/rails_que_0/config/environment"

    Que::Adapters::Base::CAST_PROCS[1184] = lambda do |value|
      case value
      when Time then value
      when String then Time.parse(value)
      else raise "Unexpected time class: #{value.class} (#{value.inspect})"
      end
    end
  elsif VERSION_QUE < VERSION_2_0_0
    require_relative "../../env/rails_que_1/config/environment"
  else
    require_relative "../../env/rails_que_2/config/environment"
  end

  def setup
    prepare_database
  end

  def test_job_queue_latency_without_jobs
    assert_equal 0, HireFire::Macro::Que.job_queue_latency
  end

  def test_job_queue_latency_with_jobs
    enqueue(job_options: {job_class: "BasicJob", queue: "default", run_at: Time.now - 60})
    enqueue(job_options: {job_class: "BasicJob", queue: "default", run_at: Time.now})
    enqueue(job_options: {job_class: "BasicJob", queue: "mailer", run_at: Time.now - 120})
    assert_in_delta 120, HireFire::Macro::Que.job_queue_latency, LATENCY_DELTA
    assert_in_delta 60, HireFire::Macro::Que.job_queue_latency(:default), LATENCY_DELTA
    assert_in_delta 120, HireFire::Macro::Que.job_queue_latency(:default, :mailer), LATENCY_DELTA
  end

  def test_job_queue_latency_with_scheduled_jobs
    enqueue(job_options: {job_class: "BasicJob", run_at: Time.now - 60})
    enqueue(job_options: {job_class: "BasicJob", run_at: Time.now + 90})
    assert_in_delta 60, HireFire::Macro::Que.job_queue_latency, LATENCY_DELTA
  end

  def test_job_queue_latency_skip_finished_jobs
    return if VERSION_QUE < VERSION_1_0_0
    job = enqueue(job_options: {job_class: "BasicJob", run_at: Time.now - 60})
    Que.execute("UPDATE que_jobs SET finished_at = NOW() WHERE id = #{job.que_attrs[:id]};")
    assert_equal 0, HireFire::Macro::Que.job_queue_latency
  end

  def test_job_queue_latency_skip_expired_jobs
    return if VERSION_QUE < VERSION_1_0_0
    job = enqueue(job_options: {job_class: "BasicJob", run_at: Time.now - 60})
    Que.execute("UPDATE que_jobs SET expired_at = NOW() WHERE id = #{job.que_attrs[:id]};")
    assert_equal 0, HireFire::Macro::Que.job_queue_latency
  end

  def test_job_queue_size_without_jobs
    assert_equal 0, HireFire::Macro::Que.job_queue_size
  end

  def test_job_queue_size_with_jobs
    enqueue(job_options: {job_class: "BasicJob", queue: "default", run_at: Time.now})
    enqueue(job_options: {job_class: "BasicJob", queue: "mailer", run_at: Time.now})
    assert_equal 2, HireFire::Macro::Que.job_queue_size
    assert_equal 1, HireFire::Macro::Que.job_queue_size(:default)
    assert_equal 2, HireFire::Macro::Que.job_queue_size(:default, :mailer)
  end

  def test_job_queue_size_with_scheduled_jobs
    enqueue(job_options: {job_class: "BasicJob", run_at: Time.now - 100})
    enqueue(job_options: {job_class: "BasicJob", run_at: Time.now + 100})
    assert_equal 1, HireFire::Macro::Que.job_queue_size
  end

  def test_job_queue_size_skip_finished_jobs
    return if VERSION_QUE < VERSION_1_0_0
    job = enqueue(job_options: {job_class: "BasicJob", run_at: Time.now})
    Que.execute("UPDATE que_jobs SET finished_at = NOW() WHERE id = #{job.que_attrs[:id]};")
    assert_equal 0, HireFire::Macro::Que.job_queue_size
  end

  def test_job_queue_size_skip_expired_jobs
    return if VERSION_QUE < VERSION_1_0_0
    job = enqueue(job_options: {job_class: "BasicJob", run_at: Time.now})
    Que.execute("UPDATE que_jobs SET expired_at = NOW() WHERE id = #{job.que_attrs[:id]};")
    assert_equal 0, HireFire::Macro::Que.job_queue_size
  end

  def test_deprecated_queue_method
    enqueue(job_options: {job_class: "BasicJob", queue: "default", run_at: Time.now})
    assert_equal 1, HireFire::Macro::Que.queue(:default)
  end

  private

  def enqueue(*args, job_options: {}, **options)
    options =
      if VERSION_QUE < VERSION_1_0_0
        options.merge(job_options)
      else
        options.merge(job_options: job_options)
      end

    Que.enqueue(*args, **options)
  end

  def prepare_database
    db_config = Rails.configuration.database_configuration[Rails.env]

    ActiveRecord::Base.establish_connection(db_config)

    begin
      ActiveRecord::Base.connection
    rescue ActiveRecord::NoDatabaseError
      ActiveRecord::Tasks::DatabaseTasks.create(db_config)
      ActiveRecord::Base.establish_connection(db_config)
    end

    Que.connection = ::ActiveRecord

    ActiveRecord::Migration.verbose = false
    ActiveRecord::MigrationContext.new(Rails.root.join("db/migrate").to_s).migrate

    Que.execute("DELETE FROM que_jobs")
  end
end
