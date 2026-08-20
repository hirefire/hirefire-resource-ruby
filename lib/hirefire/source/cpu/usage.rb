# frozen_string_literal: true

require "etc"

module HireFire
  module Source
    class CPU
      module Usage
        module_function

        CGROUP_V2_USAGE = "/sys/fs/cgroup/cpu.stat"
        CGROUP_V1_USAGE = "/sys/fs/cgroup/cpuacct/cpuacct.usage"
        CGROUP_V2_QUOTA = "/sys/fs/cgroup/cpu.max"
        CGROUP_V1_QUOTA = "/sys/fs/cgroup/cpu/cpu.cfs_quota_us"
        CGROUP_V1_PERIOD = "/sys/fs/cgroup/cpu/cpu.cfs_period_us"
        CEDAR_MEMORY_LIMIT = "/sys/fs/cgroup/memory/memory.limit_in_bytes"
        PROC_STAT_GLOB = "/proc/[0-9]*/stat"

        CEDAR_SHARED_ENTITLEMENTS = {
          536_870_912 => 1.0,
          1_073_741_824 => 2.0
        }.freeze

        def total_seconds
          reading.first
        end

        def reading
          if (seconds = cgroup_v2_seconds)
            [seconds, :cgroup_v2]
          elsif (seconds = cgroup_v1_seconds)
            [seconds, :cgroup_v1]
          elsif (seconds = proc_namespace_seconds)
            [seconds, :proc]
          elsif (seconds = process_seconds)
            [seconds, :process]
          else
            [nil, nil]
          end
        end

        def cgroup_v2_seconds
          line = read(CGROUP_V2_USAGE)&.lines&.find { |l| l.start_with?("usage_usec") }
          return unless line

          parts = line.split
          usec = number(parts[1]) if parts.length > 1
          usec / 1_000_000.0 unless usec.nil?
        end

        def cgroup_v1_seconds
          usage = number(read(CGROUP_V1_USAGE))
          usage / 1_000_000_000.0 unless usage.nil?
        end

        def proc_namespace_seconds
          paths = Dir.glob(PROC_STAT_GLOB)
          return if paths.empty?

          ticks = 0
          counted = false
          paths.each do |path|
            content = read(path) or next
            t = stat_ticks(content) or next
            ticks += t
            counted = true
          end

          ticks.to_f / positive_clock_ticks if counted
        end

        def stat_ticks(content)
          close = content.rindex(")")
          return unless close

          fields = content[(close + 1)..].split
          return if fields.length < 13

          utime = Integer(fields[11], 10, exception: false)
          stime = Integer(fields[12], 10, exception: false)
          return if utime.nil? || stime.nil?

          utime + stime
        end

        def clock_ticks
          Etc.sysconf(Etc::SC_CLK_TCK)
        rescue StandardError, NotImplementedError
          100
        end

        def positive_clock_ticks
          ticks = clock_ticks.to_i
          ticks.positive? ? ticks : 100
        end

        def process_seconds
          Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
        rescue StandardError, NotImplementedError
          nil
        end

        def available_cpus
          cgroup_v2_quota || cgroup_v1_quota || heroku_entitlement || render_entitlement || processor_count
        end

        def cgroup_v2_quota
          value = read(CGROUP_V2_QUOTA)
          return unless value

          quota, period = value.split
          return if quota.nil? || quota == "max"

          quota = number(quota)
          period = number(period)
          return if quota.nil? || period.nil? || quota <= 0 || period <= 0

          quota / period
        end

        def cgroup_v1_quota
          quota = read(CGROUP_V1_QUOTA)&.to_i
          period = read(CGROUP_V1_PERIOD)&.to_f
          return if quota.nil? || quota <= 0 || period.nil? || period <= 0

          quota / period
        end

        def heroku_entitlement
          return unless ENV["DYNO"]

          limit = read(CEDAR_MEMORY_LIMIT)
          CEDAR_SHARED_ENTITLEMENTS[limit.to_i] if limit
        end

        def render_entitlement
          return unless ENV["RENDER"]

          count = ENV["RENDER_CPU_COUNT"].to_f
          count if count.positive?
        end

        def processor_count
          Etc.nprocessors
        end

        def read(path)
          File.read(path).strip if File.readable?(path)
        rescue SystemCallError
          nil
        end

        def number(value)
          Float(value, exception: false)
        end
      end
    end
  end
end
