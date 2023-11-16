# frozen_string_literal: true

require "json"
require "net/http"

module HireFire
  # The Web class handles collecting and dispatching web metrics to HireFire's servers. It is
  # designed to work efficiently in different web server architectures, both non-forked and
  # forked. Each process in a forked environment, like Puma workers, will have its own Web instance
  # for independent metric collection and dispatch.  It is thread-safe, suitable for multithreaded
  # servers, using a Mutex to prevent race conditions.
  class Web
    # Raised for network-related issues, such as connectivity problems or DNS failures, encountered
    # during communication with HireFire's servers.
    class NetworkError < StandardError; end

    # Raised when a request to HireFire's servers times out. This typically indicates network
    # congestion or an unresponsive server.
    class TimeoutError < StandardError; end

    # Raised when HireFire's servers return a 5xx status, indicating a server-side error.
    class ServerError < StandardError; end

    # The interval (in seconds) between attempts to dispatch metrics. The default value strikes a
    # balance between timely updates and minimizing network traffic.
    DISPATCH_INTERVAL = 5

    # The timeout (in seconds) for HTTP requests. This value is chosen to promptly detect
    # unresponsive network conditions while allowing for typical network latency.
    DISPATCH_TIMEOUT = 5

    # Age threshold (in seconds) for discarding metrics. Metrics older than this are considered
    # stale and are not dispatched, ensuring the relevance and timeliness of the data sent.
    BUFFER_TTL = 60

    def initialize
      # Stores request queue time metrics with timestamps. It's a hash mapping
      # timestamps to arrays of metrics. Metrics older than `BUFFER_TTL` are discarded
      # to maintain relevance and minimize memory usage.
      @buffer = {}
      @mutex = Mutex.new # Ensures thread-safe access to @buffer.
      @running = false # Indicates the state of the dispatcher (running or not).
    end

    # Starts the dispatcher in a new thread, sending metrics at intervals set by
    # `DISPATCH_INTERVAL`. If the dispatcher is already running, this method does nothing. Logs the
    # dispatcher's state upon starting.
    def start
      @mutex.synchronize do
        return if @running
        @running = true
      end

      logger.info "[HireFire] Starting web metrics dispatcher."

      @dispatcher = Thread.new do
        while running?
          begin
            dispatch
          rescue => e
            logger.error "[HireFire] Unexpected error during dispatch: #{e.message}"
          end
          sleep DISPATCH_INTERVAL
        end
      end
    end

    # Stops the dispatcher thread, halting metric dispatch. If the dispatcher isn't running, this
    # method does nothing. Waits for the dispatcher's thread to complete, up to `DISPATCH_TIMEOUT`,
    # before marking it as stopped.  Logs the dispatcher's state upon stopping. Clears the buffer
    # after stopping.
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

    # Returns the running state of the dispatcher.
    #
    # @return [Boolean] True if running, false otherwise.
    def running?
      @mutex.synchronize { @running }
    end

    # Adds a metric value to the buffer with the current timestamp. Thread-safe.
    #
    # @param value [Integer] The request queue time in milliseconds.
    def add_to_buffer(value)
      @mutex.synchronize do
        timestamp = Time.now.to_i
        @buffer[timestamp] ||= []
        @buffer[timestamp] << value
      end
    end

    # Clears and returns the buffer's contents. Ensures no data duplication in dispatch.
    #
    # @return [Hash] Buffer contents prior to clearing.
    def flush
      @mutex.synchronize do
        @buffer.tap { @buffer = {} }
      end
    end

    # Dispatches buffer contents to HireFire's servers. Skips dispatch if buffer is empty.  Handles
    # exceptions by logging and repopulating the buffer.
    def dispatch
      return unless (buffer = flush).any?
      submit_buffer(buffer)
    rescue => e
      repopulate_buffer(buffer)
      logger.warn "[HireFire] Error while dispatching web metrics: #{e.message}"
    end

    private

    # Provides a logger instance from HireFire's global configuration for logging messages.
    #
    # @return [Logger] The configured logger.
    def logger
      HireFire.configuration.logger
    end

    # Merges given buffer contents back into the main buffer, discarding entries older than
    # `BUFFER_TTL`.
    #
    # @param buffer [Hash] Buffer contents to merge back.
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

    # Sends buffer contents to HireFire's servers via a secure HTTPS POST request. Handles HTTP
    # success and error responses, raising exceptions for error statuses.
    #
    # @param buffer [Hash] The buffer contents to send.
    # @return [Net::HTTPResponse] Server response.
    # @raise [NetworkError, TimeoutError, ServerError] For various error scenarios.
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
        raise ServerError, "Server responded with #{response.code} status."
      else
        raise NetworkError, "Unexpected response code #{response.code}."
      end
    rescue Timeout::Error
      raise TimeoutError, "Request timed out."
    rescue SocketError => e
      raise NetworkError, "Network error occurred (#{e.message})."
    rescue => e
      raise NetworkError, "An unexpected error occurred (#{e.message})."
    end
  end
end
