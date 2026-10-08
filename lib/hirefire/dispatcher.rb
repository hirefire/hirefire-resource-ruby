# frozen_string_literal: true

module HireFire
  class Dispatcher
    RQT_BACKFILL_LIMIT = 60
    PAYLOAD_SIZE_LIMIT = 131_072
    METRIC_VALUE_LIMIT = 1e15
    DEFAULT_DISPATCH_FREQUENCY = 1
    MAX_DISPATCH_FREQUENCY = 30
    BACKOFF_DOUBLINGS = 5
    FAILURE_LOG_INTERVAL = 60
    SAMPLE_ROUND_LIMIT = 60
    JOIN_TIMEOUT = 5
    TICK = 1

    def initialize(configuration)
      @configuration = configuration
      @mutex = Mutex.new
      @session = nil
      @pid = nil
      @stopping = false
    end

    def start
      return false if healthy?

      @mutex.synchronize do
        return false if @stopping || healthy?

        @session&.halt
        reset_after_fork if @pid && @pid != Process.pid
        @session = Session.new(@configuration).start
        @pid = Process.pid
      end

      Log.safe(logger, :info, "[HireFire] Starting dispatcher.")

      true
    rescue => e
      Log.safe(logger, :error, "[HireFire] Could not start dispatcher: #{e.message}")
      false
    end

    def stop(flush: true)
      session = @mutex.synchronize do
        return false if @stopping || !@session&.live?

        @stopping = true
        @session.tap { @session = nil }
      end

      begin
        session.halt(handoff: flush)
        if !flush
          @configuration.buffer.discard
        elsif @pid != Process.pid || session.join(JOIN_TIMEOUT)
          session.flush
          session.close
        else
          Log.safe(logger, :warn, "[HireFire] The dispatch loop did not stop within " \
            "#{JOIN_TIMEOUT} seconds. The final flush is skipped.")
        end

        Log.safe(logger, :info, "[HireFire] Dispatcher stopped.")

        true
      ensure
        @mutex.synchronize { @stopping = false }
      end
    end

    def running?
      @mutex.synchronize { healthy? }
    end

    def abandon_inherited_state!
      @mutex.synchronize do
        @session&.halt
        @session = nil
        @pid = nil
        @stopping = false
      end
      reset_after_fork
    rescue => e
      Log.safe(logger, :error, "[HireFire] Could not abandon inherited dispatcher state: #{e.message}")
    end

    private

    def healthy?
      !@stopping && @pid == Process.pid && !!@session&.alive?
    end

    def reset_after_fork
      @configuration.buffer.reinit_after_fork
      Plan.reinit_macros_after_fork(logger)
      @configuration.reset_after_fork
    end

    def logger
      @configuration.logger
    end
  end
end
