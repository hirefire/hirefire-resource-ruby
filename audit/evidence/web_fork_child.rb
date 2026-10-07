# frozen_string_literal: true

require "logger"
require_relative "../lib/fake_server"

$stdout.sync = true

HEALTHY = ->(_request) { {status: 200} }
STALL = ->(_request) { {then: :stall} }

server = Audit::FakeServer.new(&HEALTHY)
ENV["HIREFIRE_TOKEN"] = "token"
ENV["HIREFIRE_DATA_URL"] = server.url
ENV["DYNO"] = "web.1"
require "hirefire-resource"

def now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def fork_helper
  reader, writer = IO.pipe
  started = now
  pid = fork do
    reader.close
    writer.puts "#{Thread.list.size} #{HireFire.configuration.dispatcher.running?}"
    writer.close
    exit(0)
  end
  writer.close
  report = reader.read.split
  Process.wait(pid)
  {threads: report[0].to_i, running: report[1] == "true", seconds: (now - started).round(2)}
end

HireFire.configure { |config| config.logger = Logger.new(File::NULL) }
sleep(2.5)
puts "parent before the fork: dispatcher running #{HireFire.configuration.dispatcher.running?}, #{Thread.list.size} threads"

before = server.requests.size
child = fork_helper
sleep(0.5)
puts "healthy server: the child had #{child[:threads]} threads and a running dispatcher (#{child[:running]}), " \
  "it sent #{server.requests.size - before} requests, and it lived #{child[:seconds]} s"
puts "parent after the fork: dispatcher running #{HireFire.configuration.dispatcher.running?}"

server.handler = STALL
child = fork_helper
puts "stalled server: the child lived #{child[:seconds]} s"
server.stop
exit!(0)
