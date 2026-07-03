# frozen_string_literal: true

require "securerandom"

module HireFire
  class Lease
    # Bound server-supplied cadence: a zero or garbled header must not collapse it to a per-tick storm.
    TTL_BOUNDS = 5..3600
    SAMPLE_FREQUENCY_BOUNDS = 1..3600

    attr_reader :process_id, :sample_frequency

    def initialize(enabled: true)
      @enabled = enabled
      @process_id = SecureRandom.uuid
      @client = Client.new
      @ttl = 15
      @granted = false
      @expires_at = monotonic
      @next_sample_at = monotonic
      @sample_frequency = 15
      @owner_pid = Process.pid
    end

    def granted?
      @granted
    end

    def sample_if_due
      return unless @granted && monotonic >= @next_sample_at

      @next_sample_at = monotonic + @sample_frequency
      yield
    end

    def request_if_due
      reset_after_fork if @owner_pid != Process.pid
      return unless @enabled && monotonic >= @expires_at

      @expires_at = monotonic + @ttl

      begin
        response = @client.request_lease(@process_id)
      rescue
        @granted = false
        raise
      end

      if response.is_a?(Net::HTTPUnauthorized)
        @granted = false
        return
      end

      unless response.is_a?(Net::HTTPSuccess)
        @granted = false
        raise Client::RequestError, "Lease request failed with #{response.code} status."
      end

      if response.key?("HireFire-Sample-Frequency")
        @sample_frequency = response["HireFire-Sample-Frequency"].to_i.clamp(SAMPLE_FREQUENCY_BOUNDS)
      end

      if response.key?("HireFire-Lease-TTL")
        @ttl = response["HireFire-Lease-TTL"].to_i.clamp(TTL_BOUNDS)
        @expires_at = monotonic + @ttl
      end

      @granted = response["HireFire-Lease-Granted"] == "true"
    end

    def close
      @client.close
    end

    private

    def reset_after_fork
      @process_id = SecureRandom.uuid
      @granted = false
      @expires_at = monotonic
      @next_sample_at = monotonic
      @owner_pid = Process.pid
    end

    # Pace off the monotonic clock so a wall-clock step (e.g. NTP) cannot skew renewal.
    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
