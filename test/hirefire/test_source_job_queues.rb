# frozen_string_literal: true

require "test_helper"

class HireFire::Source::JobQueuesTest < Minitest::Test
  def buffer
    HireFire.configuration.buffer
  end

  def test_sample_job_queue
    HireFire.configure do |config|
      config.dyno(:worker) { 42 }
      config.dyno(:mailer) { 18 }
    end

    job_queues = HireFire.configuration.job_queues
    job_queues.sample_job_queue(job_queues.find_by_name("worker"), "jql")
    job_queues.sample_job_queue(job_queues.find_by_name("mailer"), "jqs")

    data = buffer.flush
    assert_equal 42, data["worker"]["jql"].values.first
    assert_equal 18, data["mailer"]["jqs"].values.first
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

  def test_latest_sample_wins_across_multiple_samples
    values = [5, 9].each
    HireFire.configure do |config|
      config.dyno(:worker) { values.next }
    end

    job_queue = HireFire.configuration.job_queues.find_by_name("worker")
    HireFire.configuration.job_queues.sample_job_queue(job_queue, "jql")
    HireFire.configuration.job_queues.sample_job_queue(job_queue, "jql")

    data = buffer.flush
    assert_equal 9, data["worker"]["jql"].values.first
  end

  def test_raising_sampler_is_isolated_and_logged
    log = StringIO.new
    HireFire.configure do |config|
      config.dyno(:worker) { raise "Redis down" }
      config.dyno(:mailer) { 18 }
    end
    HireFire.configuration.logger = Logger.new(log)

    job_queues = HireFire.configuration.job_queues
    job_queues.sample_job_queue(job_queues.find_by_name("worker"), "jql")
    job_queues.sample_job_queue(job_queues.find_by_name("mailer"), "jql")

    data = buffer.flush
    assert_equal 18, data["mailer"]["jql"].values.first
    refute data.key?("worker")
    assert_includes log.string, "Redis down"
  end

  def test_invalid_sample_values_are_dropped_and_logged
    log = StringIO.new
    values = ["10", nil, -1, Float::INFINITY, Float::NAN, 7].each
    HireFire.configure do |config|
      config.dyno(:worker) { values.next }
    end
    HireFire.configuration.logger = Logger.new(log)
    job_queue = HireFire.configuration.job_queues.find_by_name("worker")

    5.times { HireFire.configuration.job_queues.sample_job_queue(job_queue, "jql") }
    assert_empty buffer.flush
    assert_includes log.string, "expected a non-negative number"

    HireFire.configuration.job_queues.sample_job_queue(job_queue, "jql")
    assert_equal 7, buffer.flush["worker"]["jql"].values.first
  end

  def test_a_raising_logger_does_not_escape_sampling
    HireFire.configure do |config|
      config.dyno(:worker) { raise "Redis down" }
    end
    raising_logger = Object.new
    raising_logger.define_singleton_method(:error) { |*| raise IOError, "closed stream" }
    HireFire.configuration.logger = raising_logger

    job_queue = HireFire.configuration.job_queues.find_by_name("worker")
    HireFire.configuration.job_queues.sample_job_queue(job_queue, "jql")
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

  def test_bigdecimal_and_rational_samples_are_coerced_to_json_numbers
    require "bigdecimal"
    HireFire.configure do |config|
      config.dyno(:worker) { BigDecimal("1.5") }
      config.dyno(:mailer) { Rational(1, 4) }
    end

    job_queues = HireFire.configuration.job_queues
    job_queues.sample_job_queue(job_queues.find_by_name("worker"), "jql")
    job_queues.sample_job_queue(job_queues.find_by_name("mailer"), "jql")

    data = buffer.flush
    assert_equal 1.5, data["worker"]["jql"].values.first
    assert_equal 0.25, data["mailer"]["jql"].values.first
    payload = [{"name" => "worker", "metrics" => {"jql" => data["worker"]["jql"].transform_keys(&:to_s)}}]
    assert_includes JSON.generate(payload), "1.5"
  end

  def test_zero_sample_is_accepted
    HireFire.configure do |config|
      config.dyno(:worker) { 0 }
    end

    job_queue = HireFire.configuration.job_queues.find_by_name("worker")
    HireFire.configuration.job_queues.sample_job_queue(job_queue, "jql")

    assert_equal 0, buffer.flush["worker"]["jql"].values.first
  end
end
