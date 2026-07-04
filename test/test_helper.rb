# frozen_string_literal: true

env_file = File.expand_path("../.env", __dir__)
if File.exist?(env_file)
  File.foreach(env_file) do |line|
    line = line.strip
    next if line.empty? || line.start_with?("#") || !line.include?("=")

    key, value = line.split("=", 2)
    ENV[key.strip] ||= value.strip
  end
end

if ENV["COVERAGE"] == "true"
  require "simplecov"
  SimpleCov.start
end

ENV["RAILS_ENV"] = "test"

Bundler.require(:default)

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "hirefire-resource"

require "minitest/autorun"
require "mocha/minitest"
require "webmock/minitest"
require "timecop"

# Timecop mocks Time.now but leaves two Process clocks live; bridge both to the frozen
# wall time so a single Timecop.freeze drives every clock the code (and Sidekiq) reads:
#   - mock_process_clock freezes CLOCK_REALTIME, which Sidekiq stamps enqueued_at from.
#   - the prepend freezes CLOCK_MONOTONIC, which Timecop never freezes and which the
#     dispatcher and lease pace off.
Timecop.mock_process_clock = true

Process.singleton_class.prepend(Module.new do
  def clock_gettime(clock_id, *args)
    return Time.now.to_f if clock_id == Process::CLOCK_MONOTONIC
    super
  end
end)

class Minitest::Test
  IDENTITY_ENV = %w[HIREFIRE_SERVICE_NAME DYNO RENDER_SERVICE_NAME RENDER RENDER_CPU_COUNT].freeze

  def setup
    ENV["HIREFIRE_TOKEN"] = nil
    ENV["HIREFIRE_DATA_URL"] = nil
    ENV["HIREFIRE_VERBOSE"] = nil
    IDENTITY_ENV.each { |key| ENV[key] = nil }
    HireFire.reset
    HireFire.configuration.logger = Logger.new(File::NULL)
    super
  end

  def teardown
    ENV["HIREFIRE_TOKEN"] = nil
    ENV["HIREFIRE_DATA_URL"] = nil
    ENV["HIREFIRE_VERBOSE"] = nil
    IDENTITY_ENV.each { |key| ENV[key] = nil }
    HireFire.reset
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
