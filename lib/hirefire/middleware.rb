# frozen_string_literal: true

module HireFire
  class Middleware
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

      if HireFire.configuration.web && HireFire.configuration.token
        HireFire.configuration.web.sample(request_queue_time)
        HireFire.configuration.dispatcher.start
      end

      if HireFire.configuration.log_queue_metrics
        log_request_queue_time(request_queue_time)
      end
    end

    def log_request_queue_time(request_queue_time)
      puts "[hirefire:router] queue=#{request_queue_time}ms"
    end

    # X-Request-Start arrives in router-specific shapes: Heroku sends epoch
    # milliseconds ("1700000000000"), nginx sends "t=" plus epoch seconds with
    # fractional milliseconds ("t=1700000000.000"), Apache sends "t=" plus
    # epoch microseconds. Strip the prefix and infer the unit from the
    # magnitude — the ranges are ~3 orders apart, so epochs between 2001 and
    # 5138 are unambiguous. Anything implausible (garbage parsing to 0, a
    # pre-2001 epoch) yields nil rather than an absurd queue time.
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

      [(Time.now.to_f * 1000).to_i - milliseconds.to_i, 0].max
    end
  end
end
