# frozen_string_literal: true

require "json"
require "net/http"

module HireFire
  class Web
    DISPATCH_INTERVAL = 5
    DISPATCH_TIMEOUT = 5
    BUFFER_TTL = 60

    def initialize
      @buffer = {}
      @mutex = Mutex.new
      @running = false
    end

    def start
      @mutex.synchronize do
        return if @running
        @running = true
      end

      logger.info "[HireFire] Starting web metrics dispatcher."

      @dispatcher = Thread.new do
        while running?
          dispatch
          sleep DISPATCH_INTERVAL
        end
      end
    end

    def stop
      @mutex.synchronize do
        return unless @running
        @running = false
      end

      @dispatcher.join(DISPATCH_TIMEOUT)
      @dispatcher = nil

      flush

      logger.info "[HireFire] Web metrics dispatcher stopped."
    end

    def running?
      @mutex.synchronize { @running }
    end

    def add_to_buffer(value)
      @mutex.synchronize do
        timestamp = Time.now.to_i
        @buffer[timestamp] ||= []
        @buffer[timestamp] << value
      end
    end

    def flush
      @mutex.synchronize do
        @buffer.tap { @buffer = {} }
      end
    end

    def dispatch
      return unless (buffer = flush).any?
      submit_buffer(buffer)
    rescue => e
      repopulate_buffer(buffer)
      logger.warn "[HireFire] Error while dispatching web metrics: #{e.message}"
    end

    private

    def logger
      HireFire.configuration.logger
    end

    def repopulate_buffer(buffer)
      now = Time.now.to_i
      @mutex.synchronize do
        buffer.each do |timestamp, values|
          next if timestamp < now - BUFFER_TTL
          @buffer[timestamp] ||= []
          @buffer[timestamp].concat(values)
        end
      end
    end

    def submit_buffer(buffer)
      uri = URI.parse("https://logdrain.hirefire.io/")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = DISPATCH_TIMEOUT
      http.open_timeout = DISPATCH_TIMEOUT
      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      request["HireFire-Token"] = ENV["HIREFIRE_TOKEN"]
      request["HireFire-Resource"] = "Ruby-#{HireFire::VERSION}"
      request.body = buffer.to_json
      response = http.request(request)

      case response
      when Net::HTTPSuccess
        response
      when Net::HTTPServerError
        raise "Server responded with #{response.code} status."
      else
        raise "Unexpected response code #{response.code}."
      end
    rescue Timeout::Error
      raise "Request timed out."
    rescue SocketError => e
      raise "Network error occurred (#{e.message})."
    rescue => e
      raise "An unexpected error occurred (#{e.message})."
    end
  end
end
