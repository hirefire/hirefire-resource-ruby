# frozen_string_literal: true

module HireFire
  class Once
    LIMIT = 256

    def initialize(configuration)
      @configuration = configuration
      @mutex = Mutex.new
      @seen = {}
    end

    def log(level, kind, key = nil)
      @mutex.synchronize do
        seen = (@seen[kind] ||= {})
        return if seen[key]

        seen.shift while seen.size >= LIMIT
        seen[key] = true
      end
      Log.safe(@configuration.logger, level, yield)
    end
  end
end
