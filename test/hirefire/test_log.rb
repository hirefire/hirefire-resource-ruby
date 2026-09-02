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

  def test_safe_with_nil_logger
    assert_nil HireFire::Log.safe(nil, :error, "boom")
  end

  def test_format_error_strips_url_userinfo
    error = RuntimeError.new("redis://user:secret@127.0.0.1:6379/0 failed")
    text = HireFire::Log.format_error(error)
    refute_includes text, "secret"
    assert_includes text, "redis://***@127.0.0.1:6379/0"
  end

  def test_safe_returns_logger_result_on_success
    logger = Object.new
    logger.define_singleton_method(:info) { |msg| "logged:#{msg}" }

    assert_equal "logged:ok", HireFire::Log.safe(logger, :info, "ok")
  end
end
