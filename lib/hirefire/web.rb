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
      @dispatcher_running = false
    end

    def start_dispatcher
      @mutex.synchronize do
        return if @dispatcher_running
        @dispatcher_running = true
      end

      logger.info "[HireFire] Starting web metrics dispatcher."

      @dispatcher = Thread.new do
        while dispatcher_running?
          dispatch_buffer
          sleep DISPATCH_INTERVAL
        end
      end
    end

    def stop_dispatcher
      @mutex.synchronize do
        return unless @dispatcher_running
        @dispatcher_running = false
      end

      @dispatcher.join(DISPATCH_TIMEOUT)
      @dispatcher = nil

      flush_buffer

      logger.info "[HireFire] Web metrics dispatcher stopped."
    end

    def dispatcher_running?
      @mutex.synchronize { @dispatcher_running }
    end

    def add_to_buffer(value)
      @mutex.synchronize do
        timestamp = Time.now.to_i
        @buffer[timestamp] ||= []
        @buffer[timestamp] << value
      end
    end

    def flush_buffer
      @mutex.synchronize do
        @buffer.tap { @buffer = {} }
      end
    end

    def dispatch_buffer
      return unless (buffer = flush_buffer).any?
      submit_buffer(buffer)
    rescue => e
      repopulate_buffer(buffer)
      logger.error "[HireFire] Error while dispatching web metrics: #{e.message}"
    end

    private

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

    def logger
      HireFire.configuration.logger
    end
  end
end
