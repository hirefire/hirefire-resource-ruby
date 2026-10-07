# frozen_string_literal: true

require "json"
require "logger"
require "rbconfig"

if ARGV.first == "server"
  require_relative "../lib/fake_server"
  grant = {
    status: 200,
    headers: {"HireFire-Lease-Granted" => "true", "HireFire-Lease-TTL" => "5", "HireFire-Sample-Frequency" => "15"},
    body: JSON.generate("job_queues" => [{"name" => "worker", "strategy" => "jqs"}])
  }
  server = Audit::FakeServer.new(record: false) { |request| (request.path == "/metrics/lease") ? grant : {status: 200} }
  puts server.url
  $stdout.flush
  sleep
end

$stdout.sync = true
seconds = Integer(ARGV.fetch(0, 60))
identity = ARGV.fetch(1, "worker.1")
server = IO.popen([RbConfig.ruby, __FILE__, "server"])
ENV["HIREFIRE_DATA_URL"] = server.gets.strip
ENV["HIREFIRE_TOKEN"] = "token"
ENV["DYNO"] = identity
require "hirefire-resource"

HireFire.configure do |config|
  config.logger = Logger.new(File::NULL)
  config.dyno(:worker) { 5 }
end
sleep(5)

cpu = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
objects = GC.stat(:total_allocated_objects)
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
sleep(seconds)
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
cpu = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - cpu
objects = GC.stat(:total_allocated_objects) - objects

puts format("identity %s, %d seconds, the server in another process", identity, elapsed.round)
puts format("CPU time of the client process: %.3f s, which is %.2f s per hour and %.3f percent of one core", cpu, cpu / elapsed * 3600, cpu / elapsed * 100)
puts format("objects allocated: %d per second", objects / elapsed)
Process.kill("KILL", server.pid)
exit!(0)
