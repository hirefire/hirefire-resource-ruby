# frozen_string_literal: true

require "json"
require "logger"
require "stringio"
require_relative "../lib/fake_server"

$stdout.sync = true

GRANT = {
  status: 200,
  headers: {"HireFire-Lease-Granted" => "true", "HireFire-Lease-TTL" => "5", "HireFire-Sample-Frequency" => "1"},
  body: JSON.generate("job_queues" => [{"name" => "worker", "strategy" => "jqs"}])
}.freeze

mode = ARGV.fetch(0)
samples = 0
server = Audit::FakeServer.new do |request|
  if request.path == "/metrics/lease"
    GRANT
  else
    samples += JSON.parse(request.body).count { |entry| entry.dig("metrics", "jqs") }
    {status: 200}
  end
end
ENV["HIREFIRE_TOKEN"] = "token"
ENV["HIREFIRE_DATA_URL"] = server.url
ENV["DYNO"] = "worker.1"
require "hirefire-resource"

log = StringIO.new
$stderr = StringIO.new
calls = 0

def job_queue_thread
  HireFire.configuration.dispatcher.instance_variable_get(:@job_queue_thread)
end

case mode
when "raise"
  HireFire.configure do |config|
    config.logger = Logger.new(log)
    config.dyno(:worker) do
      calls += 1
      require "a_gem_that_is_not_installed" if calls == 2
      7
    end
  end
  sleep(8)
  puts "sampler calls: #{calls}, samples received: #{samples}"
  puts "job-queue thread alive after 8 seconds: #{job_queue_thread&.alive?.inspect}"
  puts "dispatcher reports running: #{HireFire.configuration.dispatcher.running?}"
  puts "lines in the HireFire log that mention the sampler: #{log.string.lines.count { |line| line.include?("sampler") }}"
  puts "standard error holds the report of Ruby for the dead thread: #{$stderr.string.include?("terminated with exception")}"
when "late"
  HireFire.configure { |config| config.logger = Logger.new(log) }
  puts "job-queue thread after configure, before the job library is loaded: #{job_queue_thread.inspect}"
  Sidekiq = Module.new
  sleep(5)
  puts "job-queue thread 5 seconds after the job library was loaded: #{job_queue_thread.inspect}"
  puts "a loaded job library is detected: #{HireFire::Plan.any_allowlisted_job_queue_library_loaded?}"
end
server.stop
exit!(0)
