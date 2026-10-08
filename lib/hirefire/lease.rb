# frozen_string_literal: true

require "securerandom"
require "json"

module HireFire
  class Lease
    TTL_BOUNDS = 5..3600
    SAMPLE_FREQUENCY_BOUNDS = 1..3600
    MAX_JOB_QUEUES = 256

    GrantBody = Struct.new(:job_queues, :trace, keyword_init: true)

    attr_reader :process_id, :sample_frequency, :job_queues

    def initialize(configuration)
      @configuration = configuration
      @process_id = SecureRandom.uuid
      @client = Client.new(configuration)
      @mutex = Mutex.new
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

    def trace?
      @trace
    end

    def demote!
      @mutex.synchronize { apply_demote }
    end

    def sample_if_due
      due = @mutex.synchronize do
        reset_after_fork if @owner_pid != Process.pid
        next false unless @granted && Clock.monotonic >= @next_sample_at

        @next_sample_at = Clock.monotonic + @sample_frequency
        true
      end
      yield if due
    end

    def request_if_due(hold:)
      epoch = reserve or return
      response = fetch(epoch) or return
      granted = response["HireFire-Lease-Granted"] == "true"
      grant = granted ? parse_grant_body(response.body) : empty_grant_body
      held = !granted || hold.call(grant.job_queues)

      @mutex.synchronize do
        next if @epoch != epoch

        apply_cadence(response)
        held ? apply_grant(granted, grant) : drop_grant
      end
    end

    def close
      @client.close
    end

    private

    def reserve
      @mutex.synchronize do
        reset_after_fork if @owner_pid != Process.pid
        next unless Clock.monotonic >= @expires_at

        @expires_at = Clock.monotonic + @ttl
        @epoch
      end
    end

    def fetch(epoch)
      response = begin
        @client.request_lease(@process_id)
      rescue
        raise if revoke(epoch)
        return
      end
      return response if response.ok?

      revoke(epoch)
      raise Errors::RequestError, "Lease request failed with #{response.status} status." unless response.unauthorized?
    end

    def revoke(epoch)
      @mutex.synchronize { (@epoch == epoch).tap { |current| clear_grant if current } }
    end

    def apply_cadence(response)
      if (frequency = response.integer("HireFire-Sample-Frequency"))
        frequency = frequency.clamp(SAMPLE_FREQUENCY_BOUNDS)
        @next_sample_at = [@next_sample_at, Clock.monotonic + frequency].min if frequency < @sample_frequency
        @sample_frequency = frequency
      end

      if (ttl = response.integer("HireFire-Lease-TTL"))
        @ttl = ttl.clamp(TTL_BOUNDS)
        @expires_at = Clock.monotonic + @ttl
      end
    end

    def apply_grant(granted, grant)
      @next_sample_at = Clock.monotonic if granted && !@granted
      @granted = granted
      @trace = granted && grant.trace
      @job_queues = grant.job_queues
    end

    def drop_grant
      clear_grant
      @process_id = SecureRandom.uuid
      Log.safe(@configuration.logger, :info,
        "[HireFire] Lease grant dropped: this process cannot sample the plan " \
        "(no local job-queue samplers and no executable plan adapter).")
    end

    def empty_grant_body(trace: false)
      GrantBody.new(job_queues: [], trace: trace)
    end

    def parse_grant_body(body)
      return empty_grant_body if body.nil? || body.empty?

      payload = JSON.parse(body)
      return ignore_plan("was not a JSON object") unless payload.is_a?(Hash)

      trace = payload["trace"] == true
      entries = payload["job_queues"]
      return ignore_plan("job_queues was not an array", trace: trace) unless entries.is_a?(Array)

      GrantBody.new(job_queues: plan_entries(entries), trace: trace)
    rescue JSON::ParserError
      ignore_plan("was not valid JSON")
    end

    def ignore_plan(reason, trace: false)
      Log.safe(@configuration.logger, :error, "[HireFire] Lease grant body #{reason}. Plan ignored.")
      empty_grant_body(trace: trace)
    end

    def plan_entries(entries)
      valid = entries.filter_map { |entry| normalize_entry(entry) }
      invalid = entries.size - valid.size

      if valid.size > MAX_JOB_QUEUES
        Log.safe(@configuration.logger, :error,
          "[HireFire] Lease plan truncated to #{MAX_JOB_QUEUES} job queue entries" \
          "#{" (#{invalid} invalid also skipped)" if invalid.positive?}.")
      elsif invalid.positive?
        label = (invalid == 1) ? "entry" : "entries"
        Log.safe(@configuration.logger, :error,
          "[HireFire] Lease plan skipped #{invalid} invalid job queue #{label}.")
      end

      valid.first(MAX_JOB_QUEUES)
    end

    def normalize_entry(entry)
      return unless entry.is_a?(Hash)

      name = entry["name"].to_s.strip
      strategy = entry["strategy"].to_s.strip
      return if name.empty? || strategy.empty? || name.bytesize > Identity::MAX_NAME_BYTES

      normalized = entry.merge("name" => name, "strategy" => strategy)
      normalized["adapter"] = entry["adapter"].to_s.strip if entry.key?("adapter")
      normalized
    end

    def clear_grant
      @granted = false
      @trace = false
      @job_queues = []
    end

    def apply_demote
      @epoch += 1
      clear_grant
      @expires_at = Clock.monotonic
      @next_sample_at = Clock.monotonic
    end

    def reset_after_fork
      apply_demote
      @process_id = SecureRandom.uuid
      @owner_pid = Process.pid
    end
  end
end
