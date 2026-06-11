# frozen_string_literal: true

require "etc"

module HireFire
  class CPU
    # Reads container-level CPU usage and the CPU normalization divisor, trying
    # progressively less precise sources. All reads are best-effort: a missing or
    # unreadable file returns nil so the caller can fall through.
    module Usage
      module_function

      CGROUP_V2_USAGE = "/sys/fs/cgroup/cpu.stat"
      CGROUP_V1_USAGE = "/sys/fs/cgroup/cpuacct/cpuacct.usage"
      CGROUP_V2_QUOTA = "/sys/fs/cgroup/cpu.max"
      CGROUP_V1_QUOTA = "/sys/fs/cgroup/cpu/cpu.cfs_quota_us"
      CGROUP_V1_PERIOD = "/sys/fs/cgroup/cpu/cpu.cfs_period_us"
      CEDAR_MEMORY_LIMIT = "/sys/fs/cgroup/memory/memory.limit_in_bytes"
      PROC_STAT_GLOB = "/proc/[0-9]*/stat"

      # Cedar shared dynos have no CPU limit anywhere, but each size is bound to
      # a fixed memory limit, so the memory limit identifies the size and the
      # size implies the CPU entitlement (eco/basic/standard-1x are 1x compute,
      # standard-2x is 2x). Dedicated dynos (Performance, Fir, Private) are
      # deliberately absent: their nproc is the real core count, so they fall
      # through correctly without an entry.
      CEDAR_SHARED_ENTITLEMENTS = {
        536_870_912 => 1.0,   # 512 MB: eco / basic / standard-1x
        1_073_741_824 => 2.0  # 1 GB: standard-2x
      }.freeze

      # Cumulative CPU time in seconds for the whole dyno/container. Source order,
      # first available wins:
      #
      #   1. cgroup v2 `cpu.stat usage_usec`   (Render/Docker/K8s)
      #   2. cgroup v1 `cpuacct.usage`         (older containers)
      #   3. sum of utime+stime across /proc/[pid]/stat
      #   4. this process's own CPU time (stdlib clock)
      #
      # Heroku exposes no cpu cgroup at all (only memory.limit_in_bytes), so 1/2
      # miss there and (3) carries it: `/proc` is PID-namespaced to the dyno, so
      # summing every visible process gives whole-dyno CPU — covering multi-
      # process servers (Puma cluster, Falcon forks) without a shared counter.
      # (4) is the dev/macOS last resort (no /proc); it only sees this process.
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

      # Whole-dyno CPU seconds via the PID-namespaced /proc. Returns nil where
      # /proc is absent (macOS) so the caller falls through to the stdlib clock.
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

      # utime + stime (clock ticks) from a /proc/[pid]/stat line. The comm field
      # (2nd) can contain spaces and parens, so parse from after the last ')':
      # the remaining whitespace-split fields are state, ppid, …, with utime at
      # index 11 and stime at index 12.
      def stat_ticks(content)
        close = content.rindex(")")
        return unless close

        fields = content[(close + 1)..].split
        return if fields.length < 13

        fields[11].to_i + fields[12].to_i
      end

      def clock_ticks
        Etc.sysconf(Etc::SC_CLK_TCK)
      rescue
        100
      end

      def process_seconds
        Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
      end

      # Number of CPUs to normalize usage against — the CPU the platform
      # guarantees this container, not the host's core count. First source that
      # answers wins:
      #
      #   1. cgroup quota — platforms that declare a hard CPU limit (Heroku
      #      Fir, Render, DigitalOcean, Docker/K8s with limits).
      #   2. Cedar shared-dyno entitlement — Heroku Cedar exposes no cpu cgroup
      #      at all, and shared dynos burst on an 8-core host, so nproc would
      #      both understate utilization and invert under host contention. The
      #      entitlement is inferred from the dyno's memory limit fingerprint.
      #   3. nproc — dedicated machines (Cedar Performance dynos, VMs, dev),
      #      where the host's core count is the container's.
      def available_cpus
        cgroup_v2_quota || cgroup_v1_quota || heroku_entitlement || processor_count
      end

      # Only meaningful on Heroku (gated on DYNO) — elsewhere a v1 memory limit
      # says nothing about CPU. Unrecognized fingerprints (dedicated dynos,
      # future sizes) return nil and fall through to the processor count.
      def heroku_entitlement
        return unless ENV["DYNO"]

        limit = read(CEDAR_MEMORY_LIMIT)
        CEDAR_SHARED_ENTITLEMENTS[limit.to_i] if limit
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
