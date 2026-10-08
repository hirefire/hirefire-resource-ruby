# frozen_string_literal: true

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

    MAX_BODY_BYTES = 131_072

    def self.header_integer(response, name)
      text = response[name].to_s.strip
      value = text.to_i if text.match?(/\A\d+\z/)
      value if value&.positive?
    end

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
      when Net::HTTPRequestEntityTooLarge
        :payload_too_large
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
      retried = false
      @mutex.synchronize do
        reused = reusable?(uri)
        connection(uri).request(request) { |response| read_body(response) }
      rescue Timeout::Error
        reset_connection
        raise RequestError, "Request timed out."
      rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError => e
        reset_connection
        if reused && !retried && stale_connection?(e)
          retried = true
          retry
        end
        raise RequestError, "Network error (#{e.class}: #{e.message})."
      rescue RequestError
        reset_connection
        raise
      end
    end

    def read_body(response)
      oversized = -> { raise RequestError, "Response body exceeded #{MAX_BODY_BYTES} bytes (status #{response.code})." }
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
      raw = ENV.fetch("HIREFIRE_DATA_URL", "https://data.hirefire.io")
      stripped = raw.to_s.strip.sub(/\/+\z/, "")
      stripped = "https://data.hirefire.io" if stripped.empty?
      stripped
    end

    def token
      HireFire.configuration.token
    end

    def require_token!
      return if token

      raise RequestError, <<~MSG
        HireFire token is not set.
        Set HIREFIRE_TOKEN or config.token to enable metric dispatch.
      MSG
    end
  end
end
