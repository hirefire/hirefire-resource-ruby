# frozen_string_literal: true

require_relative "../plan/hooks"
require_relative "../plan/size_only"
require_relative "deprecated/bunny"

module HireFire
  module Macro
    module Bunny
      extend HireFire::Macro::Deprecated::Bunny
      extend HireFire::Utility
      extend HireFire::Plan::Hooks
      extend HireFire::Plan::SizeOnly
      extend HireFire::Errors::JobQueueLatencyUnsupported
      extend self

      def plan_connection_options
        options = {reuse_connection: true}
        url = presence(ENV["HIREFIRE_BUNNY_URL"]) || presence(ENV["HIREFIRE_AMQP_URL"])
        options[:amqp_url] = url if url
        options
      end

      def reinit_after_fork
        @connection_mutex = Mutex.new
        @reused_connection = nil
        @reused_url = nil
      end

      def queues_required?
        true
      end

      def job_queue_size(*queues, amqp_url: nil, connection: nil, reuse_connection: false)
        require "bunny"

        queues = normalize_queues(queues, allow_empty: false)

        using_reused = connection.nil? && reuse_connection
        if using_reused
          connection = reused_connection(amqp_url)
          owned_connection = false
        else
          owned_connection = connection.nil?
          connection ||= acquire_connection(amqp_url)
        end
        channel = nil

        begin
          channel = open_channel(connection, close_connection_on_failure: owned_connection)
          queues.sum { |name| channel.queue(name, passive: true).message_count }
        rescue
          discard_reused_connection(connection) if using_reused
          raise
        ensure
          close_channel(channel)
          close_connection(connection) if owned_connection
        end
      end

      SAMPLE_CONNECTION_OPTIONS = {
        connection_timeout: 5,
        continuation_timeout: 5_000,
        read_timeout: 5,
        write_timeout: 5,
        automatically_recover: false
      }.freeze

      private

      def presence(value)
        return if value.nil?

        stripped = value.to_s.strip
        stripped unless stripped.empty?
      end

      def close_channel(channel)
        channel&.close
      rescue ::Bunny::Exception, Timeout::Error
        nil
      end

      def close_connection(connection)
        connection&.close
      rescue ::Bunny::Exception, Timeout::Error
        nil
      end

      def open_channel(connection, close_connection_on_failure:)
        connection.create_channel
      rescue
        close_connection(connection) if close_connection_on_failure
        raise
      end

      def acquire_connection(amqp_url)
        session = nil
        session = ::Bunny.new(resolve_amqp_url(amqp_url), SAMPLE_CONNECTION_OPTIONS)
        session.start
        session
      rescue
        close_connection(session)
        raise
      end

      def resolve_amqp_url(amqp_url)
        amqp_url ||
          ENV["AMQP_URL"] ||
          ENV["RABBITMQ_URL"] ||
          ENV["RABBITMQ_BIGWIG_URL"] ||
          ENV["CLOUDAMQP_URL"] ||
          "amqp://guest:guest@localhost:5672"
      end

      def reused_connection(amqp_url)
        url = resolve_amqp_url(amqp_url)
        connection_mutex.synchronize do
          if @reused_connection && @reused_url == url && connection_open?(@reused_connection)
            return @reused_connection
          end

          close_connection(@reused_connection)
          @reused_connection = nil
          @reused_url = nil
          session = acquire_connection(url)
          @reused_url = url
          @reused_connection = session
        end
      end

      def discard_reused_connection(connection)
        connection_mutex.synchronize do
          next unless @reused_connection.equal?(connection)

          close_connection(@reused_connection)
          @reused_connection = nil
          @reused_url = nil
        end
      end

      def connection_open?(connection)
        connection.respond_to?(:open?) && connection.open?
      rescue ::Bunny::Exception
        false
      end

      def connection_mutex
        @connection_mutex ||= Mutex.new
      end
    end
  end
end
