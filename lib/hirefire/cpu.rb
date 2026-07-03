# frozen_string_literal: true

module HireFire
  class CPU
    attr_reader :name

    def initialize(name)
      @name = name.to_s
      @last_usage = nil
      @last_time = nil
      @last_source = nil
    end

    def sample
      time = Time.now.to_f
      usage, source = Usage.reading

      previous_usage = @last_usage
      previous_time = @last_time
      previous_source = @last_source
      @last_usage = usage
      @last_time = time
      @last_source = source

      return if usage.nil? || previous_usage.nil? || source != previous_source

      wall_delta = time - previous_time
      usage_delta = usage - previous_usage

      return if wall_delta <= 0 || usage_delta < 0

      available = Usage.available_cpus
      return if available.nil? || available <= 0

      cores_used = usage_delta / wall_delta
      percentage = (cores_used / available * 100.0).clamp(0.0, 100.0)

      HireFire.configuration.buffer.sample_cpu(@name, percentage.round(2))
    end
  end
end
