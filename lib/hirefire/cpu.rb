# frozen_string_literal: true

module HireFire
  # CPU collector for one declared dyno name (the :cpu strategy). On each
  # dispatcher tick it reads the container's cumulative CPU time, derives the
  # utilization over the elapsed wall time, normalizes it to a 0-100 percentage
  # of the dyno's available CPU, and buffers it under its name in the samples
  # format. Self-sampled and intrinsic to this process's dyno, so it is gated by
  # process identity (only the matching process runs it) rather than the lease.
  #
  # No heartbeats and no watermark backfill: CPU is an intensive metric (a mean),
  # so a missed second just thins the fleet mean — it does not bias it the way a
  # gap would for an additive metric.
  class CPU
    attr_reader :name

    def initialize(name)
      @name = name.to_s
      @last_usage = nil
      @last_time = nil
    end

    # Buffers one normalized CPU percentage for the current second. The first
    # call only seeds the baseline (there is no previous reading to diff
    # against) and buffers nothing; returns nil when no sample is produced.
    def sample
      time = Time.now.to_f
      usage = Usage.total_seconds

      previous_usage = @last_usage
      previous_time = @last_time
      @last_usage = usage
      @last_time = time

      return if usage.nil? || previous_usage.nil?

      # A non-positive delta (a backward wall-clock step) just skips this
      # second's sample rather than producing a bogus value.
      wall_delta = time - previous_time
      return if wall_delta <= 0

      # A negative usage delta means the usage source changed between reads
      # (e.g. a cgroup file vanished and a lower-layered source answered, with
      # an unrelated counter). The fresh baseline is already seeded above, so
      # skip this second rather than buffering a fabricated clamped value.
      usage_delta = usage - previous_usage
      return if usage_delta < 0

      available = Usage.available_cpus
      return if available.nil? || available <= 0

      cores_used = usage_delta / wall_delta
      percentage = (cores_used / available * 100.0).clamp(0.0, 100.0)

      HireFire.configuration.buffer.sample_cpu(@name, percentage.round(2))
    end
  end
end
