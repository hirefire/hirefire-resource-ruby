# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"

module HireFire
  class Client
    class RequestError < StandardError; end

    STALE_CONNECTION_ERRORS = [
      EOFError,
      Errno::ECONNRESET,
      Errno::ECONNABORTED,
      Errno::EPIPE,
      Net::HTTPBadResponse,
      Net::ProtocolError
    ].freeze

    def initialize(timeout: 5)
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

      case response
      when Net::HTTPSuccess
        response
      when Net::HTTPUnauthorized
        nil
      when Net::HTTPServerError
        raise RequestError, "Server responded with #{response.code} status."
      else
        raise RequestError, "Unexpected response code #{response.code}."
      end
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
        reused = reusable?(uri)
        connection(uri).request(request)
      rescue Timeout::Error
        reset_connection
        raise RequestError, "Request timed out."
      rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError => e
        reset_connection
        retry if reused && stale_connection?(e)
        raise RequestError, "Network error (#{e.class}: #{e.message})."
      end
    end

    def connection(uri)
      return @http if reusable?(uri)

      reset_connection
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = uri.scheme == "https"
      http.read_timeout = @timeout
      http.open_timeout = @timeout
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
      @http&.finish if @http&.started?
    rescue IOError, SystemCallError
      nil
    ensure
      @http = nil
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
      ENV.fetch("HIREFIRE_DATA_URL", "https://data.hirefire.io").sub(/\/+\z/, "")
    end

    def token
      HireFire.configuration.token
    end

    def require_token!
      return if token

      raise RequestError, <<~MSG
        The HIREFIRE_TOKEN environment variable is not set.
        Set it to your HireFire token to enable metric dispatch.
      MSG
    end
  end
end
