# frozen_string_literal: true

require "securerandom"
require "json"

module HireFire
  class Lease
    TTL_BOUNDS = 5..3600
    SAMPLE_FREQUENCY_BOUNDS = 1..3600
    MAX_BODY_BYTES = 16_384
    MAX_JOB_QUEUES = 64
    MAX_NAME_BYTES = 128

    # Plan entries from the lease grant body (+"job_queues"+).
    attr_reader :process_id, :sample_frequency, :job_queues

    def initialize
      @process_id = SecureRandom.uuid
      @client = Client.new
      @ttl = 15
      @granted = false
      @expires_at = Clock.monotonic
      @next_sample_at = Clock.monotonic
      @sample_frequency = 15
      @owner_pid = Process.pid
      @job_queues = []
    end

    def granted?
      @granted
    end

    def sample_if_due
      reset_after_fork if @owner_pid != Process.pid
      return unless @granted && Clock.monotonic >= @next_sample_at

      @next_sample_at = Clock.monotonic + @sample_frequency
      yield
    end

    def request_if_due(hold:)
      reset_after_fork if @owner_pid != Process.pid
      return unless Clock.monotonic >= @expires_at

      @expires_at = Clock.monotonic + @ttl

      begin
        response = @client.request_lease(@process_id)
      rescue
        @granted = false
        @job_queues = []
        raise
      end

      if response.is_a?(Net::HTTPUnauthorized)
        @granted = false
        @job_queues = []
        return
      end

      unless response.is_a?(Net::HTTPSuccess)
        @granted = false
        @job_queues = []
        raise Client::RequestError, "Lease request failed with #{response.code} status."
      end

      if response.key?("HireFire-Sample-Frequency")
        @sample_frequency = response["HireFire-Sample-Frequency"].to_i.clamp(SAMPLE_FREQUENCY_BOUNDS)
      end

      if response.key?("HireFire-Lease-TTL")
        @ttl = response["HireFire-Lease-TTL"].to_i.clamp(TTL_BOUNDS)
        @expires_at = Clock.monotonic + @ttl
      end

      granted = response["HireFire-Lease-Granted"] == "true"
      @job_queues = granted ? parse_job_queues(response.body) : []

      if granted && !hold.call(@job_queues)
        @granted = false
        @job_queues = []
        Log.safe(HireFire.configuration.logger, :info,
          "[HireFire] Lease grant dropped: this process cannot sample the plan " \
          "(no local job-queue samplers and no executable plan adapter).")
      else
        @granted = granted
      end
    end

    def close
      @client.close
    end

    private

    # Wire body: +{ "version": 1, "job_queues": [ … ] }+.
    def parse_job_queues(body)
      return [] if body.nil? || body.empty?

      if body.bytesize > MAX_BODY_BYTES
        Log.safe(HireFire.configuration.logger, :error,
          "[HireFire] Lease grant body exceeded #{MAX_BODY_BYTES} bytes. Plan ignored.")
        return []
      end

      payload = JSON.parse(body)
      return [] unless payload.is_a?(Hash)

      entries = payload["job_queues"]
      return [] unless entries.is_a?(Array)

      accepted = []
      skipped = 0
      entries.each do |entry|
        if accepted.size >= MAX_JOB_QUEUES
          skipped += 1
          next
        end
        unless entry.is_a?(Hash)
          skipped += 1
          next
        end

        name = entry["name"].to_s
        strategy = entry["strategy"].to_s
        if name.empty? || strategy.empty? || name.bytesize > MAX_NAME_BYTES
          skipped += 1
          next
        end

        accepted << entry
      end

      if entries.size > MAX_JOB_QUEUES
        Log.safe(HireFire.configuration.logger, :error,
          "[HireFire] Lease plan truncated to #{MAX_JOB_QUEUES} job queue entries.")
      elsif skipped.positive?
        label = (skipped == 1) ? "entry" : "entries"
        Log.safe(HireFire.configuration.logger, :error,
          "[HireFire] Lease plan skipped #{skipped} invalid job queue #{label}.")
      end

      accepted
    rescue JSON::ParserError
      Log.safe(HireFire.configuration.logger, :error,
        "[HireFire] Lease grant body was not valid JSON. Plan ignored.")
      []
    end

    def reset_after_fork
      @process_id = SecureRandom.uuid
      @granted = false
      @job_queues = []
      @expires_at = Clock.monotonic
      @next_sample_at = Clock.monotonic
      @owner_pid = Process.pid
    end
  end
end
