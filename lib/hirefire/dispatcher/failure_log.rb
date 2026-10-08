# frozen_string_literal: true

module HireFire
  class Dispatcher
    class FailureLog
      attr_reader :count

      def initialize(label, configuration)
        @label = label
        @configuration = configuration
        @count = 0
        @logged_at = nil
      end

      def failed(error)
        @count += 1
        now = Clock.monotonic
        return if @logged_at && now - @logged_at < FAILURE_LOG_INTERVAL

        @logged_at = now
        attempts = " (#{@count} failed attempts in a row)" if @count > 1
        log(:error, "#{@label} error: #{Log.format_error(error)}#{attempts}")
      end

      def recovered
        log(:info, "#{@label} recovered after #{@count} failed attempts.") if @count > 1
        @count = 0
        @logged_at = nil
      end

      private

      def log(level, message)
        Log.safe(@configuration.logger, level, "[HireFire] #{message}")
      end
    end
  end
end
