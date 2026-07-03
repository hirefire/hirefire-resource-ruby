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
      time = monotonic
      usage, source = Usage.reading

      previous_usage = @last_usage
      previous_time = @last_time
      previous_source = @last_source
      @last_usage = usage
      @last_time = time
      @last_source = source

      return if usage.nil? || previous_usage.nil? || source != previous_source

      elapsed_delta = time - previous_time
      usage_delta = usage - previous_usage

      # elapsed_delta <= 0 is a backstop: the monotonic clock never steps back.
      return if elapsed_delta <= 0 || usage_delta < 0

      available = Usage.available_cpus
      return if available.nil? || available <= 0

      cores_used = usage_delta / elapsed_delta
      percentage = (cores_used / available * 100.0).clamp(0.0, 100.0)

      HireFire.configuration.buffer.sample_cpu(@name, percentage.round(2))
    end

    private

    # Measure the interval on the monotonic clock so a wall-clock step (e.g. NTP) cannot
    # distort the utilization delta. The buffered sample's bucket timestamp stays wall-clock.
    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
