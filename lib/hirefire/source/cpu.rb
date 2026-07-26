# frozen_string_literal: true

module HireFire
  module Source
    # CPU utilization source for an always-on process identity name.
    #
    # @!attribute [r] name
    #   The process name this source reports under.
    #   @return [String]
    class CPU
      attr_reader :name

      def initialize(name)
        @name = name.to_s
        @last_usage = nil
        @last_time = nil
        @last_source = nil
      end

      # Samples CPU utilization and buffers a percentage when a delta is available.
      #
      # The first sample only seeds a baseline. Later samples no-op when the usage source changes,
      # elapsed time is non-positive, usage went backwards, or available CPUs cannot be determined.
      # A successful sample is clamped to 0-100 and rounded to two decimal places.
      #
      # @return [void]
      def sample
        time = Clock.monotonic
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

        return if elapsed_delta <= 0 || usage_delta < 0

        available = Usage.available_cpus
        return if available.nil? || available <= 0

        cores_used = usage_delta / elapsed_delta
        percentage = (cores_used / available * 100.0).clamp(0.0, 100.0)

        HireFire.configuration.buffer.sample(@name, "cpu", percentage.round(2))
      end
    end
  end
end
