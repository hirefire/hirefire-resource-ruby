# frozen_string_literal: true

module HireFire
  class Middleware
    REQUEST_QUEUE_TIME_LIMIT = 60_000

    def initialize(app)
      @app = app
    end

    def call(env)
      process_request_queue_time(env)
      @app.call(env)
    end

    private

    def process_request_queue_time(env)
      request_start = env["HTTP_X_REQUEST_START"] || env["HTTP_X_QUEUE_START"]
      return unless request_start

      request_queue_time = calculate_request_queue_time(request_start)
      return unless request_queue_time

      configuration = HireFire.configuration

      if configuration.web && configuration.token
        configuration.web.sample(request_queue_time)
        configuration.dispatcher.start
      end

      if configuration.log_queue_metrics
        log_request_queue_time(request_queue_time)
      end
    rescue => e
      # Never raise the library's own bookkeeping into the customer's request.
      safe_log_error("[HireFire] Middleware error: #{e.message}")
    end

    def safe_log_error(message)
      HireFire.configuration.logger.error(message)
    rescue
      nil
    end

    def log_request_queue_time(request_queue_time)
      puts "[hirefire:router] queue=#{request_queue_time}ms"
    end

    def calculate_request_queue_time(timestamp)
      value = timestamp.to_s.delete_prefix("t=").to_f
      return if value < 1e9

      milliseconds = if value < 1e11
        value * 1000
      elsif value < 1e14
        value
      elsif value < 1e17
        value / 1000
      else
        value / 1_000_000
      end

      request_queue_time = [(Time.now.to_f * 1000).to_i - milliseconds.round, 0].max
      request_queue_time if request_queue_time <= REQUEST_QUEUE_TIME_LIMIT
    end
  end
end
