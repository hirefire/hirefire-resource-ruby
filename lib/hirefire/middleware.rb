# encoding: utf-8

module HireFire
  class Middleware

    # Initializes HireFire::Middleware.
    #
    # @param [Proc] app call with `env` to continue down the middleware stack.
    #
    def initialize(app)
      @app         = app
      @token       = ENV["HIREFIRE_TOKEN"]
      @path_prefix = get_path_prefix
    end

    # Intercepts and handles the /hirefire/test, /hirefire/development/info,
    # and /hirefire/HIREFIRE_TOKEN/info paths. If none of these paths match,
    # then then request will continue down the middleware stack.
    #
    # When HireFire::Resource.log_queue_metrics is enabled, and the HTTP_X_REQUEST_START
    # header has been injected at the Heroku Router layer, queue time information will be
    # logged to STDOUT. This data can be used by the HireFire Logdrain with the
    # Web.Logplex.QueueTime autoscaling strategy.
    #
    # Important: Don't set/update instance variables within this- or any underlying methods.
    # Doing so may result in race conditions when using threaded application servers.
    #
    # @param [Hash] env containing request information.
    #
    def call(env)
      handle_queue(env["HTTP_X_REQUEST_START"])

      if test_path?(env["PATH_INFO"])
        build_test_response
      elsif info_path?(env["PATH_INFO"])
        build_info_response
      else
        @app.call(env)
      end
    end

    private

    # Determines whether or not the test path has been requested.
    #
    # @param [String] path_info the requested path.
    # @return [Boolean] true if the requested path matches the test path.
    #
    def test_path?(path_info)
      get_path(path_info) == "/hirefire/test"
    end

    # Determines whether or not the info path has been requested.
    #
    # @param [String] path_info the requested path.
    # @return [Boolean] true if the requested path matches the info path.
    #
    def info_path?(path_info)
      get_path(path_info) == "/hirefire/#{@token || "development"}/info"
    end

    # The provided path with @path_prefix stripped off.
    #
    # @param [String] path_info the requested path.
    # @return [String] the path without the @path_prefix.
    #
    def get_path(path_info)
      if @path_prefix
        path_info.gsub(@path_prefix, "")
      else
        path_info
      end
    end

    # Builds the response for the test path.
    #
    # @return [String] in text/html format.
    #
    def build_test_response
      status  = 200
      headers = {"Content-Type" => "text/html"}
      body    = "HireFire Middleware Found!"

      [status, headers, [body]]
    end

    # Builds the response for the info path containing the configured
    # queues and their sizes based on the HireFire::Resource configuration.
    #
    # @return [String] in application/json format.
    #
    def build_info_response
      entries = HireFire::Resource.dynos.map do |config|
        %({"name":"#{config[:name]}","quantity":#{config[:quantity].call || "null"}})
      end

      status                   = 200
      headers                  = Hash.new
      headers["Content-Type"]  = "application/json"
      headers["Cache-Control"] = "must-revalidate, private, max-age=0"
      body                     = "[" + entries.join(",") + "]"

      [status, headers, [body]]
    end

    # Writes the Heroku Router queue time to STDOUT if a String was provided.
    #
    # @param [String] the timestamp from HTTP_X_REQUEST_START.
    #
    def handle_queue(value)
      HireFire::Resource.log_queue_metrics && value && log_queue(value)
    end

    # Writes the Heroku Router queue time to STDOUT.
    #
    # @param [String] the timestamp from HTTP_X_REQUEST_START.
    #
    def log_queue(value)
      STDOUT.puts("[hirefire:router] queue=#{get_queue(value)}ms")
    end

    # Calculates the difference, in milliseconds, between the
    # HTTP_X_REQUEST_START time and the current time.
    #
    # @param [String] the timestamp from HTTP_X_REQUEST_START.
    # @return [Integer] the queue time in milliseconds.
    #
    def get_queue(value)
      ms = (Time.now.to_f * 1000).to_i - value.to_i
      ms < 0 ? 0 : ms
    end

    # Configures the @path_prefix in order to handle apps
    # mounted under RAILS_RELATIVE_URL_ROOT.
    #
    def get_path_prefix
      if defined?(Rails) && Rails.application.config.relative_url_root
        Regexp.new("^" + Regexp.escape(Rails.application.config.relative_url_root))
      end
    end
  end
end
