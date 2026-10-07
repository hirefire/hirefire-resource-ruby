# frozen_string_literal: true

require "json"
require "logger"
require_relative "../lib/fake_server"

if ARGV.first == "client"
  ENV["HIREFIRE_TOKEN"] = "token"
  require "hirefire-resource"
  HireFire.configure do |config|
    config.logger = Logger.new(File::NULL)
    config.dyno(:worker) do
      sleep(Float(ARGV.fetch(2, 0)))
      5
    end
  end
  sleep(Integer(ARGV.fetch(1)) + 5)
  exit!(0)
end

clients = Integer(ARGV.fetch(0, 6))
seconds = Integer(ARGV.fetch(1, 90))
sample_frequency = 15
lease_seconds = Float(ARGV.fetch(2, 5))
latency = Float(ARGV.fetch(3, 0))
sample_seconds = Float(ARGV.fetch(4, 0))
lock = Mutex.new
holder = nil
expires_at = 0.0
grants = []
samples = 0

server = Audit::FakeServer.new do |request|
  now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  if request.path == "/metrics/lease"
    id = request.header("HireFire-Process-ID")
    lock.synchronize do
      if holder.nil? || expires_at < now || holder == id
        grants << {at: now, id: id, moved: holder != id, late: (holder == id) ? (now - expires_at).round(3) : nil}
        holder = id
        expires_at = now + lease_seconds
        {status: 200, headers: {"HireFire-Lease-Granted" => "true", "HireFire-Lease-TTL" => "5", "HireFire-Sample-Frequency" => sample_frequency.to_s}, body: JSON.generate("job_queues" => [{"name" => "worker", "strategy" => "jqs"}]), delay: latency}
      else
        {status: 200, headers: {"HireFire-Lease-Granted" => "false", "HireFire-Lease-TTL" => "5", "HireFire-Sample-Frequency" => sample_frequency.to_s}, delay: latency}
      end
    end
  else
    lock.synchronize { samples += JSON.parse(request.body).sum { |entry| entry.dig("metrics", "jqs")&.size.to_i } }
    {status: 200}
  end
end

pids = Array.new(clients) do
  sleep(rand * 1.5)
  Process.spawn({"HIREFIRE_DATA_URL" => server.url}, "ruby", "-Ilib", __FILE__, "client", seconds.to_s, sample_seconds.to_s)
end
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
sleep(seconds)
lock.synchronize do
  window = grants.select { |grant| grant[:at] - started <= seconds }
  moves = window.count { |grant| grant[:moved] } - 1
  renewals = window.reject { |grant| grant[:moved] }
  late = renewals.filter_map { |grant| grant[:late] }
  puts format("clients=%d seconds=%d server_lease=%.1fs client_ttl=5s sample_frequency=%ds response_latency=%dms sample_takes=%.1fs", clients, seconds, lease_seconds, sample_frequency, latency * 1000, sample_seconds)
  puts format("grants=%d renewals_by_holder=%d holder_changes=%d distinct_holders=%d", window.size, renewals.size, moves, window.map { |grant| grant[:id] }.uniq.size)
  puts format("holder renewed after server expiry by: min=%.2fs median=%.2fs max=%.2fs", late.min.to_f, late.sort[late.size / 2].to_f, late.max.to_f) if late.any?
  puts format("job queue samples received=%d, expected with one stable holder=%d", samples, seconds / sample_frequency + 1)
end
pids.each { |pid|
  begin
    Process.kill("KILL", pid)
  rescue
    nil
  end
}
pids.each { |pid|
  begin
    Process.wait(pid)
  rescue
    nil
  end
}
server.stop
