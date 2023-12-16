# frozen_string_literal: true

require "json"
require "net/http"

module HireFire
  class Web
    class DispatchError < StandardError; end

    def initialize
      @buffer = {}
      @mutex = Mutex.new
      @dispatcher_running = false
      @dispatch_interval = 1
      @dispatch_timeout = 5
      @buffer_ttl = 60
    end

    def start_dispatcher
      @mutex.synchronize do
        return false if @dispatcher_running
        @dispatcher_running = true
      end

      logger.info "[HireFire] Starting web metrics dispatcher."

      @dispatcher = Thread.new do
        while dispatcher_running?
          dispatch_buffer
          sleep @dispatch_interval
        end
      end

      true
    end

    def stop_dispatcher
      @mutex.synchronize do
        return false unless @dispatcher_running
        @dispatcher_running = false
      end

      @dispatcher.join(@dispatch_timeout)
      @dispatcher = nil

      flush_buffer

      logger.info "[HireFire] Web metrics dispatcher stopped."

      true
    end

    def dispatcher_running?
      @mutex.synchronize { @dispatcher_running }
    end

    def add_to_buffer(request_queue_time)
      @mutex.synchronize do
        timestamp = Time.now.to_i
        @buffer[timestamp] ||= []
        @buffer[timestamp] << request_queue_time
      end
    end

    private

    def flush_buffer
      @mutex.synchronize do
        @buffer.tap { @buffer = {} }
      end
    end

    def dispatch_buffer
      return unless (buffer = flush_buffer).any?
      logger.info "[HireFire] Dispatching web metrics: #{buffer}" if ENV["HIREFIRE_VERBOSE"]
      submit_buffer(buffer)
    rescue => e
      repopulate_buffer(buffer)
      logger.error "[HireFire] Error while dispatching web metrics: #{e.message}"
    end

    def repopulate_buffer(buffer)
      now = Time.now.to_i
      @mutex.synchronize do
        buffer.each do |timestamp, request_queue_times|
          next if timestamp < now - @buffer_ttl
          @buffer[timestamp] ||= []
          @buffer[timestamp].concat(request_queue_times)
        end
      end
    end

    def submit_buffer(buffer)
      hirefire_token = ENV["HIREFIRE_TOKEN"]

      unless hirefire_token
        raise DispatchError, <<~MSG
          The HIREFIRE_TOKEN environment variable is not set. Unable to submit
          Request Queue Time metric data. The HIREFIRE_TOKEN can be found in
          the HireFire Web UI in the web dyno manager settings.
        MSG
      end

      uri = URI.parse(ENV.fetch("HIREFIRE_DISPATCH_URL", "https://logdrain.hirefire.io/"))
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = @dispatch_timeout
      http.open_timeout = @dispatch_timeout
      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      request["HireFire-Token"] = ENV["HIREFIRE_TOKEN"]
      request["HireFire-Resource"] = "Ruby-#{HireFire::VERSION}"
      request.body = buffer.to_json
      response = http.request(request)

      case response
      when Net::HTTPSuccess
        adjust_parameters(response)
        response
      when Net::HTTPServerError
        raise DispatchError, "Server responded with #{response.code} status."
      else
        raise DispatchError, "Unexpected response code #{response.code}."
      end
    rescue Timeout::Error
      raise DispatchError, "Request timed out."
    rescue SocketError => e
      raise DispatchError, "Network error occurred (#{e.message})."
    rescue => e
      raise DispatchError, "An unexpected error occurred (#{e.message})."
    end

    def adjust_parameters(response)
      if response.key?("HireFire-Resource-Dispatch-Interval")
        @dispatch_interval = response["HireFire-Resource-Dispatch-Interval"].to_i
      end

      if response.key?("HireFire-Resource-Dispatch-Timeout")
        @dispatch_timeout = response["HireFire-Resource-Dispatch-Timeout"].to_i
      end

      if response.key?("HireFire-Resource-Buffer-TTL")
        @buffer_ttl = response["HireFire-Resource-Buffer-TTL"].to_i
      end
    end

    def logger
      HireFire.configuration.logger
    end
  end
end
