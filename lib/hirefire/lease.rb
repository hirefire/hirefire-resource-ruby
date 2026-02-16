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

    def sample_if_due
      return unless @granted && Time.now >= @next_sample_at
      yield
      @next_sample_at = Time.now + @sample_frequency
    end

    def request_if_due
      return unless @enabled && Time.now >= @expires_at

      response = @client.request_lease(@process_id)
      @expires_at = Time.now + @ttl

      unless response.is_a?(Net::HTTPSuccess)
        @granted = false
        raise Client::RequestError, "Lease request failed with #{response.code} status."
      end

      if response.key?("HireFire-Sample-Frequency")
        @sample_frequency = response["HireFire-Sample-Frequency"].to_i
      end

      if response.key?("HireFire-Lease-TTL")
        @ttl = response["HireFire-Lease-TTL"].to_i
      end

      @granted = response["HireFire-Lease-Granted"] == "true"
    end
  end
end
