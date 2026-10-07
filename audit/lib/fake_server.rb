# frozen_string_literal: true

require "socket"

module Audit
  class FakeServer
    Request = Struct.new(:verb, :path, :headers, :body, :at, keyword_init: true) do
      def header(name)
        headers.find { |key, _| key.casecmp?(name) }&.last
      end
    end

    REASONS = {200 => "OK", 401 => "Unauthorized", 413 => "Payload Too Large", 429 => "Too Many Requests", 500 => "Internal Server Error", 503 => "Service Unavailable"}.freeze

    attr_reader :port
    attr_accessor :on_accept

    def initialize(record: true, &handler)
      @handler = handler
      @record = record
      @counts = Hash.new(0)
      @on_accept = nil
      @requests = []
      @sockets = []
      @workers = []
      @accepted = 0
      @mutex = Mutex.new
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @thread = Thread.new { accept_loop }
    end

    def url
      "http://127.0.0.1:#{@port}"
    end

    def requests
      @mutex.synchronize { @requests.dup }
    end

    def request_counts
      @mutex.synchronize { @counts.dup }
    end

    def accepted
      @mutex.synchronize { @accepted }
    end

    def open_sockets
      @mutex.synchronize { @sockets.count { |socket| !socket.closed? } }
    end

    def live_threads
      @mutex.synchronize { @workers.count(&:alive?) } + (@thread.alive? ? 1 : 0)
    end

    def handler=(handler)
      @mutex.synchronize { @handler = handler }
    end

    def stop
      close(@server)
      @mutex.synchronize { @sockets.dup }.each { |socket| close(socket) }
      @thread.join(1)
    end

    private

    def accept_loop
      loop do
        socket = @server.accept
        @mutex.synchronize do
          @accepted += 1
          @sockets.reject!(&:closed?)
          @workers.select!(&:alive?)
          @sockets << socket
        end
        worker = Thread.new(socket) { |client| serve(client) }
        @mutex.synchronize { @workers << worker }
      end
    rescue IOError, SystemCallError
      nil
    end

    def serve(client)
      case @on_accept
      when :reset
        return reset(client)
      when :stall
        return stall(client)
      end

      loop do
        request = read_request(client) or break
        handler = @mutex.synchronize do
          @counts[request.path] += 1
          @requests << request if @record
          @handler
        end
        break unless respond(client, handler.call(request))
      end
    rescue IOError, SystemCallError
      nil
    ensure
      close(client)
    end

    def read_request(client)
      line = client.gets or return nil
      verb, path, = line.split
      headers = []
      while (header = client.gets)
        header = header.chomp
        break if header.empty?

        name, value = header.split(":", 2)
        headers << [name, value.to_s.strip]
      end
      length = headers.find { |name, _| name.casecmp?("Content-Length") }&.last.to_i
      body = length.positive? ? client.read(length) : ""
      Request.new(verb: verb, path: path, headers: headers, body: body.to_s, at: Process.clock_gettime(Process::CLOCK_MONOTONIC))
    end

    def respond(client, action)
      action = {status: 200} if action.nil?
      sleep(action[:delay]) if action[:delay]

      case action[:then]
      when :stall then return stall(client)
      when :reset then return reset(client)
      when :close then return false
      end

      bytes = action[:raw] || format_response(action)
      if action[:drip]
        bytes.each_char do |char|
          client.write(char)
          sleep(action[:drip])
        end
      else
        client.write(bytes)
      end

      case action[:after]
      when :close then false
      when :reset then reset(client)
      when :stall then stall(client)
      else true
      end
    end

    def format_response(action)
      status = action.fetch(:status, 200)
      body = action[:body].to_s
      headers = {"Content-Type" => "application/json", "Content-Length" => body.bytesize.to_s}.merge(action[:headers] || {})
      head = headers.map { |name, value| "#{name}: #{value}\r\n" }.join
      "HTTP/1.1 #{status} #{REASONS.fetch(status, "Status")}\r\n#{head}\r\n#{body}"
    end

    def stall(client)
      until @server.closed?
        next unless client.wait_readable(0.1)
        break if client.read_nonblock(1024, exception: false).nil?
      end
      false
    end

    def reset(client)
      client.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack("ii"))
      false
    end

    def close(io)
      io.close unless io.closed?
    rescue IOError, SystemCallError
      nil
    end
  end
end
