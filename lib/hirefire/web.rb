# frozen_string_literal: true

require "json"
require "net/http"

module HireFire
  # The Web class is responsible for collecting and dispatching web
  # metrics to the HireFire server. This class is designed to function
  # efficiently in various web server architectures, including both
  # non-forked (single-process) and forked (multi-process) server
  # models.
  #
  # In a forked environment, such as when using Puma workers, each
  # worker process will have its own Web instance. This separation
  # ensures that metrics are collected and dispatched independently by
  # each process. For this reason, it's recommended to start the Web
  # instances within a Rack middleware. This ensures that each forked
  # worker process initializes its own web instance and associated
  # dispatcher thread.
  #
  # Additionally, Web is also thread-safe, making it compatible with
  # multithreaded servers like Puma's threaded mode. This is achieved
  # using a Mutex, which ensures that concurrent collection of
  # metrics, modifications to the buffer, and other critical sections
  # by multiple threads are properly synchronized. This approach
  # prevents race conditions and maintains data integrity even when
  # operating in high concurrency environments.
  class Web
    # Raised when there is a network-related issue.
    class NetworkError < StandardError; end

    # Raised when the request to the server times out.
    class TimeoutError < StandardError; end

    # Raised when the server returns a 5xx status.
    class ServerError < StandardError; end

    # The interval between dispatch attempts in seconds.
    DISPATCH_INTERVAL = 5

    # The timeout for HTTP requests in seconds.
    TIMEOUT = 5

    # Metrics older than this value will be discarded.
    TTL = 60

    def initialize
      # @buffer is a hash where the keys are timestamps (in seconds
      # since the Epoch) and the values are arrays of request queue
      # time metrics that have been added at that particular timestamp
      # on a per-request basis. Metrics older than the TTL value
      # (defined below) will be automatically discarded, ensuring the
      # buffer contains only recent and relevant data and that memory
      # usage remains minimal.
      #
      # Example of @buffer contents:
      # {
      #   1634367001 => [3, 9],
      #   1634367002 => [10, 12, 8]
      # }
      #
      # The purpose of this structure is to batch metrics added at the
      # same second together, allowing for more efficient dispatching
      # to the HireFire server. When metrics are dispatched, the entire
      # buffer is flushed to prevent duplicate data transmission.
      @buffer = {}
      @mutex = Mutex.new
      @running = false
    end

    # Starts the dispatcher in a separate thread to continuously
    # dispatch web metrics to the HireFire server. The dispatcher will
    # attempt to send the metrics at intervals defined by the
    # `DISPATCH_INTERVAL` constant.
    #
    # If the dispatcher is already running, this method will have no
    # effect. After starting, the dispatcher will log an
    # informational message indicating its state.
    #
    # @example
    #   web = HireFire::Web.new
    #   web.start
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

    # Stops the dispatcher thread, ensuring that no further metrics
    # are dispatched to the HireFire server. If the dispatcher is not
    # currently running, this method will have no effect.
    #
    # The method waits for the dispatcher's thread to complete (up to
    # the duration specified by the `TIMEOUT` constant) before marking
    # it as stopped. After stopping, the dispatcher will log an
    # informational message indicating its state.
    #
    # @example
    #   web = HireFire::Web.new
    #   web.start
    #   # ... some time later ...
    #   web.stop
    def stop
      @mutex.synchronize do
        return unless @running
        @running = false
      end

      @dispatcher.join(TIMEOUT)
      @dispatcher = nil

      logger.info "[HireFire] Web metrics dispatcher stopped."
    end

    # @return [Boolean] True if the dispatcher is running, false otherwise.
    def running?
      @mutex.synchronize { @running }
    end

    # Adds a value to the buffer with the current timestamp.
    #
    # @param value [Integer] The request queue time in milliseconds to be added to the buffer.
    def add_to_buffer(value)
      @mutex.synchronize do
        timestamp = Time.now.to_i
        @buffer[timestamp] ||= []
        @buffer[timestamp] << value
      end
    end

    # Flushes the current buffer, returning its contents.  After
    # calling this method, the internal buffer will be reset to an
    # empty state, ensuring that the same data isn't dispatched more
    # than once.
    #
    # @return [Hash] The contents of the current buffer before it was cleared.
    def flush
      @mutex.synchronize do
        @buffer.tap { @buffer = {} }
      end
    end

    # Dispatches the buffer contents to the HireFire servers.
    #
    # The method first flushes the current buffer, ensuring that
    # metrics are cleared from the buffer once they are dispatched. If
    # the buffer is empty, no action will be taken.
    #
    # If an error occurs during the dispatch process, the flushed
    # buffer's contents are repopulated back into the main buffer so
    # that no metrics are lost. This ensures that metrics are retained
    # and can be attempted for dispatch in subsequent iterations.  Any
    # errors encountered during dispatch are also logged.
    def dispatch
      return unless (buffer = flush).any?
      submit_buffer(buffer)
    rescue => e
      repopulate_buffer(buffer)
      logger.warn "[HireFire] Error while dispatching web metrics: #{e.message}"
    end

    private

    # Retrieves the logger instance from the global configuration.
    # The logger can be changed using `HireFire::Resource.configuration.logger=`.
    #
    # @return [Logger] The logger used for logging messages.
    def logger
      HireFire::Resource.configuration.logger
    end

    # Repopulates the main buffer with the passed buffer's contents,
    # filtering out any entries older than the TTL value to ensure
    # only recent data is preserved.
    #
    # The TTL value represents the duration (in seconds) an entry
    # should be kept in the buffer before being considered stale and
    # discarded.
    #
    # @param buffer [Hash] The buffer to be merged back to the main
    #  buffer, with each key representing a timestamp and each value
    #  being an array of numbers for that timestamp.
    def repopulate_buffer(buffer)
      now = Time.now.to_i
      @mutex.synchronize do
        buffer.each do |timestamp, values|
          next if timestamp < now - TTL
          @buffer[timestamp] ||= []
          @buffer[timestamp].concat(values)
        end
      end
    end

    # Sends a POST request to the HireFire server with the buffer
    # contents.  This private method ensures that the contents of the
    # buffer are transmitted securely using HTTPS. It handles HTTP
    # success and server error responses, raising corresponding
    # exceptions for error statuses.
    #
    # @param buffer [Hash] The buffer to be sent to the server.
    # @return [Net::HTTPResponse] The server's response.
    # @raise [NetworkError] If there's any network-related issue.
    # @raise [TimeoutError] If the request times out.
    # @raise [ServerError] If the server returns a 5xx status, indicating server-side error.
    def submit_buffer(buffer)
      uri = URI.parse("https://logdrain.hirefire.io/")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = TIMEOUT
      http.open_timeout = TIMEOUT
      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      request["HireFire-Token"] = ENV["HIREFIRE_TOKEN"]
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
