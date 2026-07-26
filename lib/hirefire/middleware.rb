# frozen_string_literal: true

module HireFire
  # Rack middleware that samples request queue time from the +X-Request-Start+ (or
  # +X-Queue-Start+) header on each request. Insert it early in the middleware stack (the
  # {HireFire::Railtie} does this automatically for Rails).
  #
  # When a token is present, records a queue-time sample (milliseconds) under the process
  # {HireFire::Configuration#http_name} and starts the dispatcher. Explicit http registration is
  # optional. When +log_queue_metrics+ is true, also prints +[hirefire:router] queue=…ms+.
  # Failures in this path are logged and swallowed so the host app is unaffected.
  class Middleware
    REQUEST_QUEUE_TIME_LIMIT = 60_000

    # @param app [#call] the next Rack application
    def initialize(app)
      @app = app
    end

    # @param env [Hash] the Rack environment
    # @return [Array] the Rack response triple
    def call(env)
      process_request_queue_time(env)
      @app.call(env)
    end

    private

    def process_request_queue_time(env)
      # Prefer X-Request-Start, then X-Queue-Start. Blank / whitespace-only values are
      # absent so an empty Request-Start does not block Queue-Start fallback.
      request_start = present_header(env["HTTP_X_REQUEST_START"]) ||
        present_header(env["HTTP_X_QUEUE_START"])
      return unless request_start

      request_queue_time = calculate_request_queue_time(request_start)
      return unless request_queue_time

      configuration = HireFire.configuration

      if configuration.token
        configuration.mark_http_active!
        configuration.http_source&.sample(request_queue_time)
        configuration.dispatcher.start
        configuration.dispatcher.ensure_job_queue_loop
      end

      if configuration.log_queue_metrics
        log_request_queue_time(request_queue_time)
      end
    rescue => e
      Log.safe(HireFire.configuration.logger, :error, "[HireFire] Middleware error: #{e.message}")
    end

    def log_request_queue_time(request_queue_time)
      puts "[hirefire:router] queue=#{request_queue_time}ms"
    end

    def present_header(value)
      return if value.nil?

      stripped = value.to_s.strip
      stripped unless stripped.empty?
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
