# frozen_string_literal: true

module HireFire
  # Samples this process's container-level CPU utilization on each dispatcher
  # tick and buffers it as a 0-100 percentage of the dyno's available CPU.
  class CPU
    attr_reader :name

    def initialize(name)
      @name = name.to_s
      @last_usage = nil
      @last_time = nil
    end

    def sample
      time = Time.now.to_f
      usage = Usage.total_seconds

      previous_usage = @last_usage
      previous_time = @last_time
      @last_usage = usage
      @last_time = time

      # The first reading only seeds the baseline.
      return if usage.nil? || previous_usage.nil?

      wall_delta = time - previous_time
      usage_delta = usage - previous_usage

      # A non-positive wall delta means the clock stepped backward; a negative
      # usage delta means the usage source changed between reads (e.g. a cgroup
      # file vanished). Either way, skip the second rather than fabricate a value.
      return if wall_delta <= 0 || usage_delta < 0

      available = Usage.available_cpus
      return if available.nil? || available <= 0

      cores_used = usage_delta / wall_delta
      percentage = (cores_used / available * 100.0).clamp(0.0, 100.0)

      HireFire.configuration.buffer.sample_cpu(@name, percentage.round(2))
    end
  end
end
