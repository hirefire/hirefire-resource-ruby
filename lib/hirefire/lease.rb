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

    GrantBody = Struct.new(:job_queues, :trace, keyword_init: true)

    # Plan entries from the lease grant body (+"job_queues"+).
    attr_reader :process_id, :sample_frequency, :job_queues

    def initialize
      @process_id = SecureRandom.uuid
      @client = Client.new
      @ttl = 15
      @granted = false
      @trace = false
      @expires_at = Clock.monotonic
      @next_sample_at = Clock.monotonic
      @sample_frequency = 15
      @owner_pid = Process.pid
      @job_queues = []
      @epoch = 0
    end

    def granted?
      @granted
    end

    # Whether the current grant asked the client to ship sample_trace on ingest.
    def trace?
      @trace
    end

    # Drop local grant state without closing the transport. Used on stop/restart so a
    # later start does not sample on a stale grant while another process holds the server lease.
    # Bumps +@epoch+ so an in-flight lease HTTP response cannot re-apply grant state.
    def demote!
      @epoch += 1
      @granted = false
      @trace = false
      @job_queues = []
      @expires_at = Clock.monotonic
      @next_sample_at = Clock.monotonic
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

      epoch = @epoch
      @expires_at = Clock.monotonic + @ttl

      begin
        response = @client.request_lease(@process_id)
      rescue
        return if @epoch != epoch

        @granted = false
        @trace = false
        @job_queues = []
        raise
      end

      return if @epoch != epoch

      if response.is_a?(Net::HTTPUnauthorized)
        @granted = false
        @trace = false
        @job_queues = []
        return
      end

      unless response.is_a?(Net::HTTPSuccess)
        @granted = false
        @trace = false
        @job_queues = []
        raise Client::RequestError, "Lease request failed with #{response.code} status."
      end

      next_sample_frequency = @sample_frequency
      next_sample_at = @next_sample_at
      if response.key?("HireFire-Sample-Frequency")
        previous_frequency = @sample_frequency
        next_sample_frequency = response["HireFire-Sample-Frequency"].to_i.clamp(SAMPLE_FREQUENCY_BOUNDS)
        if next_sample_frequency < previous_frequency
          sooner = Clock.monotonic + next_sample_frequency
          next_sample_at = sooner if next_sample_at > sooner
        end
      end

      next_ttl = @ttl
      next_expires_at = @expires_at
      if response.key?("HireFire-Lease-TTL")
        next_ttl = response["HireFire-Lease-TTL"].to_i.clamp(TTL_BOUNDS)
        next_expires_at = Clock.monotonic + next_ttl
      end

      granted = response["HireFire-Lease-Granted"] == "true"
      grant_body = granted ? parse_grant_body(response.body) : empty_grant_body

      return if @epoch != epoch

      hold_ok = !granted || hold.call(grant_body.job_queues)

      return if @epoch != epoch

      @sample_frequency = next_sample_frequency
      @next_sample_at = next_sample_at
      @ttl = next_ttl
      @expires_at = next_expires_at

      if granted && !hold_ok
        @granted = false
        @trace = false
        @job_queues = []
        @process_id = SecureRandom.uuid
        Log.safe(HireFire.configuration.logger, :info,
          "[HireFire] Lease grant dropped: this process cannot sample the plan " \
          "(no local job-queue samplers and no executable plan adapter).")
      else
        was_granted = @granted
        @granted = granted
        @trace = granted && grant_body.trace
        @job_queues = grant_body.job_queues
        @next_sample_at = Clock.monotonic if granted && !was_granted
      end
    end

    def close
      @client.close
    end

    private

    def empty_grant_body(trace: false)
      GrantBody.new(job_queues: [], trace: trace)
    end

    # Wire body: +{ "version": 1, "trace"?: true, "job_queues": [ … ] }+.
    # Returns {GrantBody}. Unknown top-level keys are tolerated.
    def parse_grant_body(body)
      return empty_grant_body if body.nil? || body.empty?

      if body.bytesize > MAX_BODY_BYTES
        Log.safe(HireFire.configuration.logger, :error,
          "[HireFire] Lease grant body exceeded #{MAX_BODY_BYTES} bytes. Plan ignored.")
        return empty_grant_body
      end

      payload = JSON.parse(body)
      unless payload.is_a?(Hash)
        Log.safe(HireFire.configuration.logger, :error,
          "[HireFire] Lease grant body was not a JSON object. Plan ignored.")
        return empty_grant_body
      end

      trace = payload["trace"] == true
      entries = payload["job_queues"]
      unless entries.is_a?(Array)
        Log.safe(HireFire.configuration.logger, :error,
          "[HireFire] Lease grant body job_queues was not an array. Plan ignored.")
        return empty_grant_body(trace: trace)
      end

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

        name = entry["name"].to_s.strip
        strategy = entry["strategy"].to_s.strip
        adapter = entry.key?("adapter") ? entry["adapter"].to_s.strip : nil
        if name.empty? || strategy.empty? || name.bytesize > MAX_NAME_BYTES
          skipped += 1
          next
        end

        normalized = entry.merge("name" => name, "strategy" => strategy)
        if entry.key?("adapter")
          normalized["adapter"] = adapter
        end
        accepted << normalized
      end

      if entries.size > MAX_JOB_QUEUES
        Log.safe(HireFire.configuration.logger, :error,
          "[HireFire] Lease plan truncated to #{MAX_JOB_QUEUES} job queue entries" \
          "#{" (#{skipped} invalid also skipped)" if skipped.positive?}.")
      elsif skipped.positive?
        label = (skipped == 1) ? "entry" : "entries"
        Log.safe(HireFire.configuration.logger, :error,
          "[HireFire] Lease plan skipped #{skipped} invalid job queue #{label}.")
      end

      GrantBody.new(job_queues: accepted, trace: trace)
    rescue JSON::ParserError
      Log.safe(HireFire.configuration.logger, :error,
        "[HireFire] Lease grant body was not valid JSON. Plan ignored.")
      empty_grant_body
    end

    def reset_after_fork
      @epoch += 1
      @process_id = SecureRandom.uuid
      @granted = false
      @trace = false
      @job_queues = []
      @expires_at = Clock.monotonic
      @next_sample_at = Clock.monotonic
      @owner_pid = Process.pid
    end
  end
end
