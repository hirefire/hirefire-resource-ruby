# frozen_string_literal: true

require_relative "deprecated/bunny"

module HireFire
  module Macro
    module Bunny
      extend HireFire::Macro::Deprecated::Bunny
      # job_queue_latency is unsupported for Bunny and always raises
      # HireFire::Errors::JobQueueLatencyUnsupportedError.
      extend HireFire::Errors::JobQueueLatencyUnsupported
      extend HireFire::Utility
      extend self

      # Calculates the total job queue size using Bunny.
      #
      # If an `amqp_url` is not provided, the method attempts to establish a connection using a
      # hierarchy of environment variables for the RabbitMQ URL. It checks the following environment
      # variables in order: `AMQP_URL`, `RABBITMQ_URL`, `RABBITMQ_BIGWIG_URL`, `CLOUDAMQP_URL`. If
      # none of these variables are set, it defaults to a local RabbitMQ instance at
      # "amqp://guest:guest@localhost:5672".
      #
      # @note It's important to separate jobs scheduled for future execution into a different queue
      #   from the regular queue. This is because including them in the regular queue can interfere
      #   with the accurate counting of jobs that are currently scheduled to run, leading to
      #   premature upscaling. If you want to be able to schedule jobs to run in the future,
      #   consider using the Delayed Message Plugin for RabbitMQ.
      #
      # @note The method relies on the `message_count` metric to determine the number of "Ready" messages
      #   in the queue. When using auto-acknowledgment, messages are acknowledged immediately upon delivery,
      #   causing the `message_count` to drop to zero, even if the consumer is processing messages. To ensure
      #   accurate metrics:
      #   - Enable manual acknowledgment (`manual_ack: true`) so that RabbitMQ tracks unacknowledged messages.
      #   - Set a reasonable prefetch limit (`channel.prefetch(x)`) to control the number of messages delivered
      #     to the consumer, allowing a measurable backlog to remain in the "Ready" state.
      #   This configuration ensures accurate scaling metrics and prevents premature depletion of the queue.
      #
      # @param queues [Array<String, Symbol>] Names of the queues for size measurement.
      # @param amqp_url [String, nil] (optional) RabbitMQ URL for establishing a new connection.
      #   Ignored when +connection+ is given.
      # @param connection [Bunny::Session, nil] (optional) An existing, started connection to
      #   reuse. When given, it takes precedence over +amqp_url+: it is left open (the caller owns
      #   it) and only a per-call channel is opened and closed; otherwise a new connection is opened
      #   and closed on each call. Reusing a long-lived connection avoids a TCP + AMQP handshake on
      #   every poll.
      # @return [Integer] Total job queue size.
      # @raise [HireFire::Errors::MissingQueueError] If no queue names are specified.
      # @raise [Bunny::Exception] If a queue does not exist (a passive declare returns a 404) or
      #   the connection cannot be established.
      # @example Retrieve job queue size for the "default" queue
      #   HireFire::Macro::Bunny.job_queue_size(:default)
      # @example Retrieve job queue size across "default" and "mailer" queues
      #   HireFire::Macro::Bunny.job_queue_size(:default, :mailer)
      # @example Use a new connection on each call using an AMQP URL
      #   HireFire::Macro::Bunny.job_queue_size(:default, amqp_url: url)
      # @example Reuse a long-lived connection across calls
      #   HireFire::Macro::Bunny.job_queue_size(:default, connection: connection)
      def job_queue_size(*queues, amqp_url: nil, connection: nil)
        require "bunny"

        queues = normalize_queues(queues, allow_empty: false)

        owned_connection = connection.nil?
        connection ||= acquire_connection(amqp_url)
        channel = open_channel(connection, close_connection_on_failure: owned_connection)

        begin
          queues.sum { |name| channel.queue(name, passive: true).message_count }
        ensure
          close_channel(channel)
          close_connection(connection) if owned_connection
        end
      end

      private

      # A passive declare of a missing queue makes the broker close the channel
      # (404). Closing an already-closed channel raises, which in this ensure
      # block would mask the original error and skip the connection close,
      # leaking the connection.
      def close_channel(channel)
        channel&.close
      rescue ::Bunny::Exception, Timeout::Error
        nil
      end

      # Likewise isolated: a failing connection close (e.g. a broken socket)
      # must not mask the body's error or supersede the channel close.
      def close_connection(connection)
        connection&.close
      rescue ::Bunny::Exception, Timeout::Error
        nil
      end

      def open_channel(connection, close_connection_on_failure:)
        connection.create_channel
      rescue
        # create_channel runs before the caller's begin/ensure, so a channel-open
        # failure on a connection we own would leak it. A borrowed connection is
        # left for its owner to manage.
        close_connection(connection) if close_connection_on_failure
        raise
      end

      def acquire_connection(amqp_url)
        url = amqp_url ||
          ENV["AMQP_URL"] ||
          ENV["RABBITMQ_URL"] ||
          ENV["RABBITMQ_BIGWIG_URL"] ||
          ENV["CLOUDAMQP_URL"] ||
          "amqp://guest:guest@localhost:5672"

        ::Bunny.new(url).tap(&:start)
      end
    end
  end
end
