# frozen_string_literal: true

require "logger"
require_relative "../lib/fake_server"

state = ARGV.fetch(0)
server = Audit::FakeServer.new { |_request| {status: 200} }
ENV["HIREFIRE_DATA_URL"] = server.url
ENV["DYNO"] = "web.1"
ENV["HIREFIRE_TOKEN"] = "token" unless state == "no_token"
require "hirefire-resource"

HireFire.configure do |config|
  config.logger = Logger.new(File::NULL)
  config.dyno(:worker) { 1 } if state == "token_with_sampler"
end

inner = ->(_env) { [200, {}, []] }
app = (state == "bare") ? inner : HireFire::Middleware.new(inner)
env = {"HTTP_X_REQUEST_START" => "t=#{Time.now.to_f}"}
20_000.times { app.call(env) }

calls = 300_000
GC.start
allocated = GC.stat(:total_allocated_objects)
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
calls.times { app.call(env) }
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
objects = GC.stat(:total_allocated_objects) - allocated

puts format("%-20s %7.0f ns per call  %5.1f objects per call", state, elapsed / calls * 1e9, objects.to_f / calls)
HireFire.configuration.stop_dispatcher(flush: false)
server.stop
