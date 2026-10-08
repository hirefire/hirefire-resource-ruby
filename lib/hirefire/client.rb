# frozen_string_literal: true

require "net/http"
require "openssl"
require "timeout"

module HireFire
  class Client
    STALE_CONNECTION_ERRORS = [
      EOFError,
      Errno::ECONNRESET,
      Errno::ECONNABORTED,
      Errno::EPIPE,
      Net::HTTPBadResponse,
      Net::ProtocolError
    ].freeze

    TIMEOUT = 5
    MAX_BODY_BYTES = 131_072
    DEFAULT_URL = "https://data.hirefire.io"
    LOCAL_HOSTS = ["localhost", "127.0.0.1", "::1"].freeze

    Response = Struct.new(:status, :headers, :body) do
      def ok?
        status.between?(200, 299)
      end

      def unauthorized?
        status == 401
      end

      def too_large?
        status == 413
      end

      def [](name)
        headers[name]
      end

      def integer(name)
        text = self[name].to_s.strip
        value = text.to_i if text.match?(/\A\d+\z/)
        value if value&.positive?
      end
    end

    def initialize(configuration, timeout: TIMEOUT)
      @configuration = configuration
      @timeout = timeout
      @mutex = Mutex.new
      @http = nil
      @owner_pid = nil
    end

    def submit_samples(body)
      require_token!
      uri = ingest_uri
      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      request["HireFire-Token"] = token
      request["HireFire-Agent"] = "Ruby-#{HireFire::VERSION}"
      request.body = body
      response = execute(uri, request)
      return response if response.ok? || response.unauthorized? || response.too_large?

      raise Errors::RequestError, "Ingest request failed with #{response.status} status."
    end

    def request_lease(process_id)
      require_token!
      uri = lease_uri
      request = Net::HTTP::Post.new(uri.request_uri)
      request["HireFire-Token"] = token
      request["HireFire-Agent"] = "Ruby-#{HireFire::VERSION}"
      request["HireFire-Process-ID"] = process_id
      execute(uri, request)
    end

    def close
      @mutex.synchronize { reset_connection }
    end

    private

    def execute(uri, request)
      @mutex.synchronize do
        http = Timeout.timeout(@timeout) { perform(uri, request) }
        Response.new(http.code.to_i, http, http.body)
      rescue Timeout::Error
        reset_connection
        raise Errors::RequestError, "Request timed out."
      rescue Errors::RequestError
        reset_connection
        raise
      end
    end

    def perform(uri, request)
      retried = false
      begin
        reused = reusable?(uri)
        connection(uri).request(request) { |response| read_body(response) }
      rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError => e
        reset_connection
        if reused && !retried && stale_connection?(e)
          retried = true
          retry
        end
        raise Errors::RequestError, "Network error (#{e.class}: #{e.message})."
      end
    end

    def read_body(response)
      oversized = -> { raise Errors::RequestError, "Response body exceeded #{MAX_BODY_BYTES} bytes (status #{response.code})." }
      oversized.call if response.content_length.to_i > MAX_BODY_BYTES

      body = "".b
      response.read_body do |chunk|
        body << chunk
        oversized.call if body.bytesize > MAX_BODY_BYTES
      end
      response.body = body
    end

    def connection(uri)
      return @http if reusable?(uri)

      reset_connection
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @timeout
      http.read_timeout = @timeout
      http.write_timeout = @timeout
      http.keep_alive_timeout = 60
      http.start
      @owner_pid = Process.pid
      @http = http
    end

    def reusable?(uri)
      @http&.started? && @owner_pid == Process.pid &&
        @http.address == uri.host && @http.port == uri.port
    end

    def reset_connection
      if @http && @owner_pid == Process.pid
        @http.finish if @http.started?
      end
    rescue IOError, SystemCallError
      nil
    ensure
      @http = nil
      @owner_pid = nil
    end

    def stale_connection?(error)
      STALE_CONNECTION_ERRORS.any? { |klass| error.is_a?(klass) }
    end

    def ingest_uri
      @ingest_uri ||= URI.parse("#{base_url}/metrics/ingest")
    end

    def lease_uri
      @lease_uri ||= URI.parse("#{base_url}/metrics/lease")
    end

    def base_url
      @base_url ||= begin
        url = ENV["HIREFIRE_DATA_URL"].to_s.strip.sub(/\/+\z/, "")
        url = DEFAULT_URL if url.empty?
        uri = parse_http_url(url)
        raise Errors::RequestError, "HIREFIRE_DATA_URL must be an http or https URL with a host." unless uri

        if uri.scheme == "http" && !LOCAL_HOSTS.include?(uri.hostname)
          @configuration.warn_plain_http_data_url_once(uri.hostname)
        end
        url
      end
    end

    def parse_http_url(url)
      uri = URI.parse(url)
      uri if uri.is_a?(URI::HTTP) && uri.hostname
    rescue URI::InvalidURIError
      nil
    end

    def token
      @configuration.token
    end

    def require_token!
      return if token

      raise Errors::RequestError,
        "HireFire token is not set. Set HIREFIRE_TOKEN or config.token to enable metric dispatch."
    end
  end
end
