# frozen_string_literal: true

module HireFire
  class Dispatcher
    def initialize(web: nil, workers: Workers.new)
      @web = web
      @workers = workers
      @client = Client.new
      @lease = Lease.new(enabled: workers.any?)
      @mutex = Mutex.new
      @running = false
    end

    def start
      return false if @running

      @mutex.synchronize do
        return false if @running
        @running = true
      end

      @thread = Thread.new do
        while running?
          tick
          sleep 1
        end
      end

      logger.info "[HireFire] Starting dispatcher."

      true
    end

    def stop
      @mutex.synchronize do
        return false unless @running
        @running = false
      end

      @thread&.join(5)
      @thread = nil

      dispatch

      logger.info "[HireFire] Dispatcher stopped."

      true
    end

    def running?
      @mutex.synchronize { @running }
    end

    private

    def tick
      @lease.request_if_due
      @lease.sample_if_due { @workers.sample }
      dispatch
    rescue => e
      logger.error "[HireFire] #{e.message}"
    end

    def dispatch
      data = buffer.flush
      payload = build_payload(data)
      return if payload.empty?

      logger.info "[HireFire] Dispatching metrics: #{payload}" if ENV["HIREFIRE_VERBOSE"]
      @client.submit_samples(payload)
    rescue => e
      buffer.repopulate_web(data[:web]) if data && data[:web].any?
      logger.error "[HireFire] Dispatch error: #{e.message}"
    end

    def build_payload(data)
      entries = []

      if @web
        samples = if data[:web].any?
          data[:web].transform_keys(&:to_s)
        else
          {Time.now.to_i.to_s => []} # heartbeat
        end
        entries << {"name" => @web.name, "samples" => samples}
      end

      entries.concat(data[:workers])

      entries
    end

    def buffer
      HireFire.configuration.buffer
    end

    def logger
      HireFire.configuration.logger
    end
  end
end
