# frozen_string_literal: true

require "json"

module HireFire
  # HireFire::Middleware provides a Rack middleware for capturing and providing metrics required for
  # autoscaling Heroku web and worker dynos. It serves two primary roles:
  #
  # 1. It responds to specific HTTP requests with JSON-formatted queue metrics.
  # 2. It captures and processes request queue time data from incoming HTTP requests, forwarding it
  #    to `HireFire::Web` for further handling or logging it for HireFire Logdrain capture,
  #    depending on configuration.
  #
  # The middleware intercepts requests to the HireFire info endpoints and allows all other requests
  # to pass through unaffected. The `HTTP_X_REQUEST_START` header, set by the Heroku router,
  # provides the data for measuring request queue times.
  #
  # In a Rails application, this middleware is automatically injected into the stack.  For other
  # Ruby frameworks, it should be manually inserted as early as possible in the middleware stack to
  # ensure accurate capture of request queue times.
  class Middleware
    # Creates a new `Middleware` instance. When the Rack framework constructs the middleware stack,
    # this initializer is called.
    #
    # The `@path_prefix` is determined to accommodate Rails applications mounted at subpaths,
    # ensuring correct pattern matching for incoming request paths.
    #
    # @param app [#call] The next component in the middleware stack,
    #   typically another middleware or the main application.
    def initialize(app)
      @app = app
      @path_prefix = determine_path_prefix
    end

    # Processes incoming HTTP requests by first analyzing the request queue time, if present, and
    # then determining whether to respond with queue metrics or pass the request along the stack.
    # If the request path matches a HireFire info endpoint, it returns a JSON response with worker
    # queue metrics; otherwise, it delegates to the subsequent middleware or application.
    #
    # @param env [Hash] The Rack environment hash containing request details.
    # @return [Array] A Rack-compatible response array or the result
    #   of calling the next component in the stack.
    def call(env)
      process_request_queue_time(env)

      return construct_info_response if matches_info_path?(env)

      @app.call(env)
    end

    private

    # Determines if the given request path aligns with the info path.
    #
    # @param env [Hash] The hash containing request specifics.
    # @return [Boolean] True if paths align, otherwise false.
    def matches_info_path?(env)
      ENV["HIREFIRE_TOKEN"] && extract_path(env) == "/hirefire/#{ENV["HIREFIRE_TOKEN"]}/info"
    end

    # Eliminates the path prefix from the request path.
    #
    # @param env [Hash] The hash containing request specifics.
    # @return [String] The path after removing the `@path_prefix`.
    def extract_path(env)
      @path_prefix ? env["PATH_INFO"].gsub(@path_prefix, "") : env["PATH_INFO"]
    end

    # Creates the HTTP response for the info path, containing worker queue metrics based on
    # `HireFire.configuration.workers` configuration.
    #
    # @return [Array] A tuple consisting of the HTTP status code,
    #   headers, and response body.
    def construct_info_response
      [
        200,
        {
          "Content-Type" => "application/json",
          "Cache-Control" => "must-revalidate, private, max-age=0"
        },
        [
          HireFire.configuration.workers.map do |worker|
            {name: worker.name, value: worker.call}
          end.to_json
        ]
      ]
    end

    # Analyzes the request queue time (if present) based on the `HTTP_X_REQUEST_START` header and
    # performs actions based on the configuration settings in `HireFire.configuration`.
    #
    # It will dispatch the request queue time via `HireFire::Web` or log the metric if the
    # respective configurations are enabled. If both `HireFire::Web` and `log_queue_metrics` are
    # enabled, `HireFire::Web` takes precedence.
    #
    # @param env [Hash] The hash containing request specifics.
    def process_request_queue_time(env)
      return unless (timestamp = env["HTTP_X_REQUEST_START"])

      if HireFire.configuration.web && ENV["HIREFIRE_TOKEN"]
        collect_request_queue_time(
          calculate_request_queue_time(timestamp)
        )
      elsif HireFire.configuration.log_queue_metrics
        log_request_queue_time(
          calculate_request_queue_time(timestamp)
        )
      end
    end

    # Forwards the request queue time metric to HireFire::Web's buffer for eventual dispatch to
    # HireFire's servers.
    #
    # @note Starts HireFire::Web's dispatcher thread if it is not already running.
    # @param request_queue_time [Integer] Request queue time in milliseconds.
    def collect_request_queue_time(request_queue_time)
      HireFire
        .configuration
        .web
        .tap(&:start)
        .add_to_buffer(request_queue_time)
    end

    # Logs the request queue time to STDOUT in a structured format that is recognized by
    # HireFire. Heroku's Logplex captures all STDOUT logs, including this one, and forwards them to
    # the configured endpoints such as HireFire's Logdrain. HireFire's Logdrain uses this
    # information to determine how to autoscale.
    #
    # @param request_queue_time [Integer] The request queue time in milliseconds to be logged.
    def log_request_queue_time(request_queue_time)
      puts "[hirefire:router] queue=#{request_queue_time}ms"
    end

    # Calculates the time gap (in milliseconds) between the given `X-Request-Start` timestamp and
    # the present time.
    #
    # @param timestamp [String] Timestamp from the `X-Request-Start` header.
    # @return [Integer] The computed queue time in milliseconds.
    def calculate_request_queue_time(timestamp)
      [(Time.now.to_f * 1000).to_i - timestamp.to_i, 0].max
    end

    # Identifies the path prefix based on Rails' relative URL root, if applicable.  This adjustment
    # is necessary for applications not mounted at the root path and ensures that the middleware can
    # correctly identify and respond to requests to the HireFire info endpoints.
    #
    # @return [Regexp, nil] A regular expression matching the path
    #   prefix, or nil if no subpath mounting is configured.
    def determine_path_prefix
      if defined?(Rails) && Rails.application.config.relative_url_root
        Regexp.new("^" + Regexp.escape(Rails.application.config.relative_url_root))
      end
    end
  end
end
