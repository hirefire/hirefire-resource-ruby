# encoding: utf-8

module HireFire
  class Middleware

    # Initialize the HireFire::Middleware and store the `app` in `@app`
    # and `ENV["HIREFIRE_TOKEN"]` in `@token` for convenience.
    #
    # @param [ActionDispatch::Routing::RouteSet] app.
    #
    def initialize(app)
      @app   = app
      @token = ENV["HIREFIRE_TOKEN"]
    end

    # Will respond to the request here if either the `test` or the `info` url was requested.
    # Otherwise, fall through to the rest of the middleware below HireFire::Middleware.
    #
    # @param [Hash] env containing request information.
    #
    def call(env)
      @env = env

      if test?
        [ 200, {"Content-Type" => "text/html"}, self ]
      elsif info?
        [ 200, {"Content-Type" => "application/json"}, self ]
      else
        @app.call(env)
      end
    end

    # Returns text/html when the `test` url is requested.
    # This is purely to see whether the URL works through the HireFire command-line utility.
    #
    # Returns a JSON String when the `info` url is requested.
    # This url will be requested every minute by HireFire in order to fetch dyno data.
    #
    # @return [text/html, application/json] based on whether the `test` or `info` url was requested.
    #
    def each(&block)
      if test?
        block.call "HireFire Middleware Found!"
      elsif info?
        block.call(dynos)
      end
    end

    private

    # Generates a JSON string by calling dynos.to_json
    #
    # @return [String] in JSON format.
    #
    def dynos
      HireFire::Resource.dynos.to_json
    end

    # Returns true if the PATH_INFO matches the test url.
    #
    # @return [Boolean] true if the requested url matches the test url.
    #
    def test?
      @env["PATH_INFO"] == "/hirefire/test"
    end

    # Returns true if the PATH_INFO matches the info url.
    #
    # @return [Boolean] true if the requested url matches the info url.
    #
    def info?
      @env["PATH_INFO"] == "/hirefire/#{@token || "development"}/info"
    end
  end
end
