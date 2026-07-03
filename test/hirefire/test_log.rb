# frozen_string_literal: true

require "test_helper"

class HireFire::LogTest < Minitest::Test
  def test_delegates_to_the_logger
    logger = Logger.new(log = StringIO.new)

    HireFire::Log.safe(logger, :error, "boom")

    assert_includes log.string, "boom"
  end

  def test_swallows_a_raising_logger
    logger = Object.new
    logger.define_singleton_method(:error) { |*| raise IOError, "closed stream" }

    assert_nil HireFire::Log.safe(logger, :error, "boom")
  end

  def test_skips_a_logger_that_does_not_respond_to_the_level
    logger = Object.new

    assert_nil HireFire::Log.safe(logger, :error, "boom")
  end
end
