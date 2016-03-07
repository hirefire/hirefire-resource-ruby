# encoding: utf-8

module HireFire
  class Middleware

    # Frozen headers to save some memory
    TEST_HEADERS = {
      'Content-Type' => 'text/html'
    }.freeze
    INFO_HEADERS = {
        'Content-Type' => 'application/json',
        'Cache-Control' => 'must-revalidate, private, max-age=0'
    }.freeze

    # Initialize the HireFire::Middleware and store the `app` in `@app`
    # and `ENV["HIREFIRE_TOKEN"]` in `@token` for convenience.
    #
    # @param [ActionDispatch::Routing::RouteSet] app.
    #
    def initialize(app)
      @app   = app
      @token = ENV["HIREFIRE_TOKEN"]
      if defined?(Rails) && Rails.application.config.relative_url_root
        @path_prefix = Regexp.new("^" + Regexp.escape(Rails.application.config.relative_url_root))
      end
    end

    # Will respond to the request here if either the `test` or the `info` url was requested.
    # Otherwise, fall through to the rest of the middleware below HireFire::Middleware.
    #
    # @param [Hash] env containing request information.
    #
    def call(env)
      @env = env

      if test?
        [ 200, TEST_HEADERS, self ]
      elsif info?
        [ 200, INFO_HEADERS, self ]
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

    # Generates a JSON string based on the dyno data.
    #
    # @return [String] in JSON format.
    #
    def dynos
      dyno_data = HireFire::Resource.dynos.inject(String.new) do |json, dyno|
        json << %|,{"name":"#{dyno[:name]}","quantity":#{dyno[:quantity].call || "null"}}|; json
      end

      "[#{dyno_data.sub(",","")}]"
    end


    # Rack PATH_INFO with any RAILS_RELATIVE_URL_ROOT stripped off
    def path
      if @path_prefix
        @env["PATH_INFO"].gsub(@path_prefix, "")
      else
        @env["PATH_INFO"]
      end
    end

    # Returns true if the PATH_INFO matches the test url.
    #
    # @return [Boolean] true if the requested url matches the test url.
    #
    def test?
      path == "/hirefire/test"
    end

    # Returns true if the PATH_INFO matches the info url.
    #
    # @return [Boolean] true if the requested url matches the info url.
    #
    def info?
      path == "/hirefire/#{@token || "development"}/info"
    end
  end
end
