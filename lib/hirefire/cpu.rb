# frozen_string_literal: true

module HireFire
  # Samples this process's CPU utilization as a 0-100% of available CPU.
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

      return if usage.nil? || previous_usage.nil?

      wall_delta = time - previous_time
      usage_delta = usage - previous_usage

      # Skip rather than fabricate: the clock stepped back, or the usage source
      # changed between reads.
      return if wall_delta <= 0 || usage_delta < 0

      available = Usage.available_cpus
      return if available.nil? || available <= 0

      cores_used = usage_delta / wall_delta
      percentage = (cores_used / available * 100.0).clamp(0.0, 100.0)

      HireFire.configuration.buffer.sample_cpu(@name, percentage.round(2))
    end
  end
end
