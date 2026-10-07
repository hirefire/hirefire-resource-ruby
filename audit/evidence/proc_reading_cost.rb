# frozen_string_literal: true

require "benchmark"
require "hirefire-resource"

usage = HireFire::Source::CPU::Usage
puts "source this container would use: #{usage.reading.last.inspect}"
children = []
[10, 100, 500, 1000].each do |target|
  children << spawn("sleep", "600") while Dir.glob("/proc/[0-9]*/stat").size < target
  processes = Dir.glob("/proc/[0-9]*/stat").size
  runs = 50
  seconds = Benchmark.realtime { runs.times { usage.proc_namespace_seconds } }
  cpu = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
  objects = GC.stat(:total_allocated_objects)
  runs.times { usage.proc_namespace_seconds }
  cpu = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - cpu
  objects = GC.stat(:total_allocated_objects) - objects
  puts format("%4d processes: %.2f ms per reading, %.2f ms of CPU, %d objects", processes, seconds / runs * 1000, cpu / runs * 1000, objects / runs)
end
children.each { |pid| Process.kill("KILL", pid) }
