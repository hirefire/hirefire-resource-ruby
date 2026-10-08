# frozen_string_literal: true

require "test_helper"

class HireFire::Dispatcher::FailureLogTest < Minitest::Test
  def setup
    super
    @log = StringIO.new
    HireFire.configuration.logger = Logger.new(@log)
    @failure_log = HireFire::Dispatcher::FailureLog.new("Dispatch", HireFire.configuration)
  end

  def lines
    @log.string.lines.map { |line| line[/\[HireFire\].*/] }
  end

  def fail_at(seconds)
    HireFire::Clock.stubs(:monotonic).returns(1_000.0 + seconds)
    @failure_log.failed(RuntimeError.new("down"))
  end

  def test_the_first_failure_is_logged_without_a_count
    fail_at(0)

    assert_equal ["[HireFire] Dispatch error: RuntimeError: down"], lines
    assert_equal 1, @failure_log.count
  end

  def test_a_failure_inside_the_interval_is_counted_and_not_logged
    fail_at(0)
    fail_at(59.9)

    assert_equal 1, lines.size
    assert_equal 2, @failure_log.count
  end

  def test_a_failure_at_the_interval_is_logged_with_the_count
    fail_at(0)
    fail_at(60)

    assert_equal "[HireFire] Dispatch error: RuntimeError: down (2 failed attempts in a row)", lines.last
  end

  def test_a_recovery_after_one_failure_logs_nothing_and_after_two_logs_the_count
    fail_at(0)
    @failure_log.recovered
    assert_equal 1, lines.size
    assert_equal 0, @failure_log.count

    fail_at(1)
    fail_at(2)
    @failure_log.recovered

    assert_equal "[HireFire] Dispatch recovered after 2 failed attempts.", lines.last
    assert_equal 0, @failure_log.count
  end

  def test_the_first_failure_after_a_recovery_is_logged_at_once
    fail_at(0)
    @failure_log.recovered
    fail_at(1)

    assert_equal ["[HireFire] Dispatch error: RuntimeError: down"] * 2, lines
  end

  def test_a_recorded_message_is_logged_as_given_and_limited_like_a_failure
    HireFire::Clock.stubs(:monotonic).returns(1_000.0)
    2.times { @failure_log.record("Dropped a payload.") }
    HireFire::Clock.stubs(:monotonic).returns(1_060.0)
    @failure_log.record("Dropped a payload.")

    assert_equal ["[HireFire] Dropped a payload.", "[HireFire] Dropped a payload. (3 failed attempts in a row)"], lines
  end
end
