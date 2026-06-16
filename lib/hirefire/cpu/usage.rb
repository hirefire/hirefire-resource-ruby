# frozen_string_literal: true

require "etc"

module HireFire
  class CPU
    # Best-effort reads of container CPU usage and the normalization divisor.
    module Usage
      module_function

      CGROUP_V2_USAGE = "/sys/fs/cgroup/cpu.stat"
      CGROUP_V1_USAGE = "/sys/fs/cgroup/cpuacct/cpuacct.usage"
      CGROUP_V2_QUOTA = "/sys/fs/cgroup/cpu.max"
      CGROUP_V1_QUOTA = "/sys/fs/cgroup/cpu/cpu.cfs_quota_us"
      CGROUP_V1_PERIOD = "/sys/fs/cgroup/cpu/cpu.cfs_period_us"
      CEDAR_MEMORY_LIMIT = "/sys/fs/cgroup/memory/memory.limit_in_bytes"
      PROC_STAT_GLOB = "/proc/[0-9]*/stat"

      # Cedar shared dynos expose no CPU limit; the memory limit fingerprints the
      # size, which implies the entitlement. Other sizes fall through.
      CEDAR_SHARED_ENTITLEMENTS = {
        536_870_912 => 1.0,   # 512 MB: eco / basic / standard-1x
        1_073_741_824 => 2.0  # 1 GB: standard-2x
      }.freeze

      # Cumulative whole-container CPU seconds, first available source wins.
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

      # Heroku exposes no cpu cgroup; /proc is PID-namespaced to the dyno, so
      # summing every visible process gives whole-dyno CPU.
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

      # utime + stime ticks; parse after the last ")" since comm may contain
      # spaces and parens, which puts utime at index 11 and stime at index 12.
      def stat_ticks(content)
        close = content.rindex(")")
        return unless close

        fields = content[(close + 1)..].split
        return if fields.length < 13

        fields[11].to_i + fields[12].to_i
      end

      # Etc.sysconf raises NotImplementedError without sysconf; 100 is the
      # universal USER_HZ default.
      def clock_ticks
        Etc.sysconf(Etc::SC_CLK_TCK)
      rescue StandardError, NotImplementedError
        100
      end

      def process_seconds
        Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
      end

      # CPUs to normalize against: the platform's guarantee, not the host core
      # count. First source wins.
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

      # Gated on DYNO: a v1 memory limit says nothing about CPU off Heroku.
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
