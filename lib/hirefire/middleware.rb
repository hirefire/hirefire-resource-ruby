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

      if HireFire.configuration.web && HireFire.configuration.token && request_start
        request_queue_time = calculate_request_queue_time(request_start)
        HireFire.configuration.web.sample(request_queue_time)
        HireFire.configuration.dispatcher.start
      end

      if HireFire.configuration.log_queue_metrics && request_start
        request_queue_time = calculate_request_queue_time(request_start)
        log_request_queue_time(request_queue_time)
      end
    end

    def log_request_queue_time(request_queue_time)
      puts "[hirefire:router] queue=#{request_queue_time}ms"
    end

    def calculate_request_queue_time(timestamp)
      [(Time.now.to_f * 1000).to_i - timestamp.to_i, 0].max
    end
  end
end
