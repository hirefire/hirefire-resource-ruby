# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"

module HireFire
  class Client
    class RequestError < StandardError; end

    def initialize(timeout: 5)
      @timeout = timeout
    end

    # Takes the JSON-encoded body; the dispatcher encodes it to enforce
    # PAYLOAD_SIZE_LIMIT before submitting.
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
      request["HireFire-Process-ID"] = process_id
      execute(uri, request)
    end

    private

    # Maps the whole transport failure family (DNS, refused/reset connections,
    # broken pipes, TLS) to RequestError so callers handle one error type.
    def execute(uri, request)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.read_timeout = @timeout
      http.open_timeout = @timeout
      http.request(request)
    rescue Timeout::Error
      raise RequestError, "Request timed out."
    rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError => e
      raise RequestError, "Network error (#{e.class}: #{e.message})."
    end

    def ingest_uri
      @ingest_uri ||= URI.parse("#{base_url}/metrics/ingest")
    end

    def lease_uri
      @lease_uri ||= URI.parse("#{base_url}/metrics/lease")
    end

    def base_url
      ENV.fetch("HIREFIRE_DATA_URL", "https://data.hirefire.io")
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
