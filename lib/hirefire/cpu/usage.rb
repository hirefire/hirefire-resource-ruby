# frozen_string_literal: true

require "etc"

module HireFire
  class CPU
    # Reads container-level CPU usage and the CPU normalization divisor, trying
    # progressively less precise sources. All reads are best-effort: a missing
    # or unreadable file returns nil so the caller can fall through.
    module Usage
      module_function

      CGROUP_V2_USAGE = "/sys/fs/cgroup/cpu.stat"
      CGROUP_V1_USAGE = "/sys/fs/cgroup/cpuacct/cpuacct.usage"
      CGROUP_V2_QUOTA = "/sys/fs/cgroup/cpu.max"
      CGROUP_V1_QUOTA = "/sys/fs/cgroup/cpu/cpu.cfs_quota_us"
      CGROUP_V1_PERIOD = "/sys/fs/cgroup/cpu/cpu.cfs_period_us"
      CEDAR_MEMORY_LIMIT = "/sys/fs/cgroup/memory/memory.limit_in_bytes"
      PROC_STAT_GLOB = "/proc/[0-9]*/stat"

      # Cedar shared dynos have no CPU limit anywhere, but each size is bound
      # to a fixed memory limit, so the memory limit identifies the size and
      # the size implies the CPU entitlement. Dedicated dynos are deliberately
      # absent: their nproc is the real core count, so they fall through.
      CEDAR_SHARED_ENTITLEMENTS = {
        536_870_912 => 1.0,   # 512 MB: eco / basic / standard-1x
        1_073_741_824 => 2.0  # 1 GB: standard-2x
      }.freeze

      # Cumulative CPU time in seconds for the whole dyno/container, from the
      # first available source: cgroup v2, cgroup v1, the /proc PID namespace,
      # or this process's own clock. Heroku exposes no cpu cgroup at all, so
      # /proc carries it there: it is PID-namespaced to the dyno, so summing
      # every visible process gives whole-dyno CPU — covering multi-process
      # servers without a shared counter. The stdlib clock is the dev/macOS
      # last resort and only sees this process.
      def total_seconds
        cgroup_v2_seconds || cgroup_v1_seconds || proc_namespace_seconds || process_seconds
      end

      def cgroup_v2_seconds
        line = read(CGROUP_V2_USAGE)&.lines&.find { |l| l.start_with?("usage_usec") }
        line.split.last.to_f / 1_000_000.0 if line
      end

      def cgroup_v1_seconds
        usage = read(CGROUP_V1_USAGE)
        usage.to_f / 1_000_000_000.0 if usage
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

        ticks.to_f / clock_ticks if counted
      end

      # utime + stime (clock ticks) from a /proc/[pid]/stat line. The comm
      # field (2nd) can contain spaces and parens, so parse from after the last
      # ')': the remaining fields put utime at index 11 and stime at index 12.
      def stat_ticks(content)
        close = content.rindex(")")
        return unless close

        fields = content[(close + 1)..].split
        return if fields.length < 13

        fields[11].to_i + fields[12].to_i
      end

      # Etc.sysconf raises NotImplementedError (not a StandardError) on
      # platforms without sysconf; 100 is the universal USER_HZ default.
      def clock_ticks
        Etc.sysconf(Etc::SC_CLK_TCK)
      rescue StandardError, NotImplementedError
        100
      end

      def process_seconds
        Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
      end

      # Number of CPUs to normalize usage against — the CPU the platform
      # guarantees this container, not the host's core count. Sources, first
      # answer wins: a cgroup quota (platforms with a hard CPU limit), the
      # Cedar shared-dyno entitlement (shared dynos burst on an 8-core host,
      # so nproc would understate utilization and invert under contention), or
      # nproc (dedicated machines, where the host's core count is the
      # container's).
      def available_cpus
        cgroup_v2_quota || cgroup_v1_quota || heroku_entitlement || processor_count
      end

      def cgroup_v2_quota
        value = read(CGROUP_V2_QUOTA)
        return unless value

        quota, period = value.split
        return if quota.nil? || quota == "max"

        period = period.to_f
        quota.to_f / period if period > 0
      end

      def cgroup_v1_quota
        quota = read(CGROUP_V1_QUOTA)&.to_i
        period = read(CGROUP_V1_PERIOD)&.to_f
        return if quota.nil? || quota <= 0 || period.nil? || period <= 0

        quota / period
      end

      # Gated on DYNO because elsewhere a v1 memory limit says nothing about
      # CPU. Unrecognized fingerprints (dedicated dynos, future sizes) fall
      # through to the processor count.
      def heroku_entitlement
        return unless ENV["DYNO"]

        limit = read(CEDAR_MEMORY_LIMIT)
        CEDAR_SHARED_ENTITLEMENTS[limit.to_i] if limit
      end

      def processor_count
        Etc.nprocessors
      end

      def read(path)
        File.read(path).strip if File.readable?(path)
      rescue SystemCallError
        nil
      end
    end
  end
end
