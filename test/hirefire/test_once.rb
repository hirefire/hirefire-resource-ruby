# frozen_string_literal: true

require "test_helper"

class HireFire::OnceTest < Minitest::Test
  def setup
    super
    @log = StringIO.new
    HireFire.configuration.logger = Logger.new(@log)
    @once = HireFire::Once.new(HireFire.configuration)
  end

  def test_a_line_is_logged_the_first_time_and_not_again
    3.times { @once.log(:warn, :cpu_unresolved) { "no identity" } }

    assert_equal 1, @log.string.scan("no identity").size
    assert_match(/WARN/, @log.string)
  end

  def test_the_message_is_not_built_for_a_line_that_was_logged_before
    built = 0
    2.times { @once.log(:error, :problem, "worker") { (built += 1).to_s } }

    assert_equal 1, built
  end

  def test_each_key_of_a_kind_and_each_kind_gets_its_own_line
    @once.log(:error, :unknown_adapter, "worker") { "first" }
    @once.log(:error, :unknown_adapter, "mailer") { "second" }
    @once.log(:error, :unloaded_adapter, "worker") { "third" }
    @once.log(:error, :unknown_adapter, ["worker", "sidekiq"]) { "fourth" }
    @once.log(:error, :unknown_adapter, "worker") { "fifth" }

    assert_equal %w[first second third fourth], @log.string.lines.map { |line| line.split.last }
  end

  def test_the_line_is_logged_at_the_level_given
    @once.log(:info, :a) { "informed" }
    @once.log(:error, :b) { "failed" }

    assert_match(/INFO -- : informed/, @log.string)
    assert_match(/ERROR -- : failed/, @log.string)
  end

  def test_a_kind_remembers_its_last_256_keys
    assert_equal 256, HireFire::Once::LIMIT
    (1..HireFire::Once::LIMIT).each { |index| @once.log(:warn, :queue, index) { "line" } }
    @once.log(:warn, :queue, 1) { "line" }
    assert_equal HireFire::Once::LIMIT, @log.string.scan("line").size

    @once.log(:warn, :queue, HireFire::Once::LIMIT + 1) { "line" }
    @once.log(:warn, :queue, 2) { "line" }
    @once.log(:warn, :queue, 1) { "line" }
    assert_equal HireFire::Once::LIMIT + 2, @log.string.scan("line").size
  end

  def test_threads_that_arrive_together_log_one_line
    gate = Queue.new
    threads = Array.new(8) do
      Thread.new do
        gate.pop
        @once.log(:warn, :together) { "together" }
      end
    end
    8.times { gate << true }
    threads.each(&:join)

    assert_equal 1, @log.string.scan("together").size
  end

  def test_the_logger_in_use_when_the_line_is_due_receives_it
    later = StringIO.new
    HireFire.configuration.logger = Logger.new(later)

    @once.log(:warn, :swapped) { "to the new logger" }

    assert_empty @log.string
    assert_includes later.string, "to the new logger"
  end

  def test_a_logger_that_raises_does_not_raise_into_the_caller
    broken = Object.new
    broken.define_singleton_method(:warn) { |_message| raise IOError, "closed stream" }
    HireFire.configuration.logger = broken

    @once.log(:warn, :broken) { "lost" }
  end
end
