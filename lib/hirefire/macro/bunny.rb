# frozen_string_literal: true

require_relative "deprecated/bunny"

module HireFire
  module Macro
    module Bunny
      extend HireFire::Macro::Deprecated::Bunny
      extend HireFire::Errors::JobQueueLatencyUnsupported
      extend HireFire::Utility
      extend self

      class ConnectionError < StandardError; end

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
      # @return [Integer] Total job queue size.
      # @raise [HireFire::Errors::MissingQueueError] If no queue names are specified.
      # @example Retrieve job queue size for the "default" queue
      #   HireFire::Macro::Bunny.job_queue_size(:default)
      # @example Retrieve job queue size across "default" and "mailer" queues
      #   HireFire::Macro::Bunny.job_queue_size(:default, :mailer)
      # @example Use a new connection on each call using a AMQP URL
      #   HireFire::Macro::Bunny.job_queue_size(:default, amqp_url: url)
      def job_queue_size(*queues, amqp_url: nil)
        require "bunny"

        queues = normalize_queues(queues, allow_empty: false)
        channel, connection = setup_channel(amqp_url)

        begin
          queues.sum { |name| channel.queue(name, passive: true).message_count }
        ensure
          channel&.close
          connection&.close
        end
      end

      private

      def setup_channel(amqp_url)
        connection = acquire_connection(amqp_url)

        if connection
          [connection.create_channel, connection]
        else
          raise ConnectionError, <<~ERROR_MSG
            Unable to establish connection with RabbitMQ.
            Ensure that a valid AMQP URL is provided.
          ERROR_MSG
        end
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
