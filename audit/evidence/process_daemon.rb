# frozen_string_literal: true

require "logger"
require_relative "../lib/fake_server"

out = ARGV.fetch(0)
server = Audit::FakeServer.new { |_request| {status: 200} }
ENV["HIREFIRE_TOKEN"] = "token"
ENV["HIREFIRE_DATA_URL"] = server.url
ENV["HIREFIRE_SERVICE_NAME"] = "worker"
require "hirefire-resource"

HireFire.configure { |config| config.logger = Logger.new(File::NULL) }
before = HireFire.configuration.dispatcher.running?
Process.daemon(true, true)
sleep(3)
File.write(out, "running before daemon: #{before}\nrunning 3 seconds after daemon: #{HireFire.configuration.dispatcher.running?}\nthreads after daemon: #{Thread.list.size}\n")
exit!(0)
