# frozen_string_literal: true

if ENV["COVERAGE"] == "true"
  require "simplecov"
  SimpleCov.start
end

ENV["RAILS_ENV"] = "test"

Bundler.require(:default)

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "hirefire-resource"

require "minitest/autorun"
require "minitest/unit"
require "mocha/minitest"
require "webmock/minitest"
require "timecop"

Timecop.mock_process_clock = true

class Minitest::Test
  def setup
    ENV["HIREFIRE_TOKEN"] = nil
    HireFire.configuration = HireFire::Configuration.new
    super
  end

  def teardown
    ENV["HIREFIRE_TOKEN"] = nil
    HireFire.configuration = HireFire::Configuration.new
    super
  end

  def capture(&block)
    original_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original_stdout
  end
end
