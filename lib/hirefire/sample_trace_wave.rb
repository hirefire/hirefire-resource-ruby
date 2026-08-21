# frozen_string_literal: true

module HireFire
  class SampleTraceWave
    def self.start
      new
    end

    def initialize
      @start = Clock.monotonic
      @ops = []
      @payload = nil
    end

    def measure(entry)
      op_start = Clock.monotonic
      result = yield
      record(entry, elapsed_ms(op_start))
      result
    end

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

    def finish
      @payload ||= {
        "wave_ms" => elapsed_ms(@start),
        "ops" => @ops.map(&:dup)
      }
    end

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
