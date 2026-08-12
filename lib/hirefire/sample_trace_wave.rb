# frozen_string_literal: true

module HireFire
  # One job-queue sample wave: monotonic start, per-op timings, finish payload for
  # +sample_trace+ / verbose logging.
  class SampleTraceWave
    def self.start
      new
    end

    def initialize
      @start = Clock.monotonic
      @ops = []
      @payload = nil
    end

    # Times +block+ and records one op for +entry+. Returns the block's result.
    def measure(entry)
      op_start = Clock.monotonic
      result = yield
      record(entry, elapsed_ms(op_start))
      result
    end

    # Records one op with a pre-measured duration in milliseconds.
    def record(entry, ms)
      @payload = nil
      entry = {} unless entry.is_a?(Hash)
      queues = entry["queues"]
      options = entry["options"]
      strategy = entry["strategy"]
      @ops << {
        "adapter" => entry["adapter"],
        "strategy" => strategy.nil? ? "" : strategy.to_s,
        "queues" => queues.is_a?(Array) ? queues : [],
        "options" => options.is_a?(Hash) ? options : {},
        "ms" => ms.to_f.round(3)
      }
      self
    end

    # Wire payload: +{ "wave_ms" => Number, "ops" => [ ... ] }+.
    # Ops is a copy so later +record+ does not mutate a previous finish handle.
    def finish
      @payload ||= {
        "wave_ms" => elapsed_ms(@start),
        "ops" => @ops.map(&:dup)
      }
    end

    # Verbose sample timing lines (same format as the former dispatcher helper).
    def log_to(logger)
      payload = finish
      Log.safe(logger, :info,
        "[HireFire] sample_job_queues wave_ms=#{payload["wave_ms"]} ops=#{payload["ops"].size}")
      payload["ops"].each do |op|
        Log.safe(logger, :info,
          "[HireFire] sample adapter=#{op["adapter"].inspect} strategy=#{op["strategy"]} " \
          "queues=#{Array(op["queues"]).join(",")} ms=#{op["ms"]}")
      end
      nil
    end

    private

    def elapsed_ms(from)
      ((Clock.monotonic - from) * 1000.0).round(3)
    end
  end
end
