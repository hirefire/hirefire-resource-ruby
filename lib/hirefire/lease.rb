# frozen_string_literal: true

require "securerandom"

module HireFire
  class Lease
    attr_reader :process_id, :sample_frequency

    def initialize(enabled: true)
      @enabled = enabled
      @process_id = SecureRandom.uuid
      @client = Client.new
      @ttl = 15
      @granted = false
      @expires_at = Time.now
      @next_sample_at = Time.now
      @sample_frequency = 15
    end

    def granted?
      @granted
    end

    # Advance before yielding so a raising sampler costs one window, not every tick.
    def sample_if_due
      return unless @granted && Time.now >= @next_sample_at

      @next_sample_at = Time.now + @sample_frequency
      yield
    end

    # Advance before the request so a failed renewal waits a full TTL, not every tick.
    def request_if_due
      return unless @enabled && Time.now >= @expires_at

      @expires_at = Time.now + @ttl

      begin
        response = @client.request_lease(@process_id)
      rescue
        # Demote on failure: an unconfirmed lease may be re-granted elsewhere, so
        # stop sampling rather than risk two processes sampling one fleet.
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
        @sample_frequency = response["HireFire-Sample-Frequency"].to_i
      end

      if response.key?("HireFire-Lease-TTL")
        @ttl = response["HireFire-Lease-TTL"].to_i
        @expires_at = Time.now + @ttl
      end

      @granted = response["HireFire-Lease-Granted"] == "true"
    end
  end
end
