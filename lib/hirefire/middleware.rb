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
      request_start = env["HTTP_X_REQUEST_START"]
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
    end

    def log_request_queue_time(request_queue_time)
      puts "[hirefire:router] queue=#{request_queue_time}ms"
    end

    # X-Request-Start arrives in router-specific shapes: Heroku sends epoch
    # milliseconds, nginx "t=" plus fractional epoch seconds, Apache "t=" plus
    # epoch microseconds. The unit is inferred from the magnitude (the ranges
    # are ~3 orders apart); implausible values yield nil.
    def calculate_request_queue_time(timestamp)
      value = timestamp.to_s.delete_prefix("t=").to_f
      return if value < 1e9

      milliseconds = if value < 1e11
        value * 1000 # epoch seconds
      elsif value < 1e14
        value # epoch milliseconds
      else
        value / 1000 # epoch microseconds
      end

      request_queue_time = [(Time.now.to_f * 1000).to_i - milliseconds.to_i, 0].max
      request_queue_time if request_queue_time <= REQUEST_QUEUE_TIME_LIMIT
    end
  end
end
