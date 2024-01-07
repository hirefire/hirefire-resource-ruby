# frozen_string_literal: true

require_relative "deprecated/bunny"

module HireFire
  module Macro
    module Bunny
      extend HireFire::Macro::Deprecated::Bunny
      extend HireFire::Errors::JobQueueLatencyUnsupported
      extend self

      # Raised when a valid connection or URL for RabbitMQ is not provided.
      class ConnectionError < StandardError; end

      # Calculates the total job queue size across the specified queues.
      #
      # @note This method may not accurately represent the immediate
      #   workload for jobs scheduled to run in the future.  These
      #   jobs are placed inside the same queue and will be included
      #   in the total count, which is a limitation of RabbitMQ.
      #   Currently, there is no workaround for this issue. It is
      #   recommended not to use this method for queues that contain
      #   scheduled jobs.
      # @param queues [Array<String, Symbol>] The names of the queues to be included in the measurement of job queue size.
      # @param connection [Bunny::Session, nil] An existing RabbitMQ connection.
      # @param amqp_url [String, nil] RabbitMQ URL for initializing a new connection.
      # @param durable [Boolean] Indicates if the queue is durable. Default is true.
      # @param max_priority [Integer, nil] Sets x-max-priority for the queue.
      # @param options [Hash] Additional Bunny options.
      # @return [Integer] Cumulative job queue size across the specified queues.
      # @raise [HireFire::Errors::MissingQueueError] Raised when no queue names are provided.
      # @example Retrieving the Job Queue Size of the default queue
      #   HireFire::Macro::Bunny.job_queue_size(:default, amqp_url: url)
      # @example Retrieving the Job Queue Size across multiple queues
      #   HireFire::Macro::Bunny.job_queue_size(:default, :mailer, amqp_url: url)
      # @example Establishing a new RabbitMQ connection
      #   HireFire::Macro::Bunny.job_queue_size(:default, amqp_url: url)
      # @example Using an existing RabbitMQ connection
      #   HireFire::Macro::Bunny.job_queue_size(:default, connection: connection)
      # @example Utilizing non-durable queues with a new RabbitMQ connection
      #   HireFire::Macro::Bunny.job_queue_size(:default, amqp_url: url, durable: false)
      # @example Setting "x-max-priority" for a queue
      #   HireFire::Macro::Bunny.job_queue_size(:default, amqp_url: url, max_priority: 10)
      def job_queue_size(*queues, connection: nil, amqp_url: nil, durable: true, max_priority: nil, **options)
        require "bunny"

        queues = Utility.construct_queues(queues)
        max_priority ||= options["x-max-priority"] || options[:"x-max-priority"]
        bunny_options = {durable: durable, arguments: {}}

        if max_priority
          bunny_options[:arguments]["x-max-priority"] = max_priority
        end

        channel, connection = setup_channel(connection, amqp_url)

        begin
          queues.sum { |name| channel.queue(name, bunny_options).message_count }
        ensure
          channel&.close
          connection&.close if amqp_url
        end
      end

      private

      def setup_channel(connection, amqp_url)
        if connection
          channel = connection.create_channel
          [channel, nil]
        elsif amqp_url
          connection = ::Bunny.new(amqp_url)
          connection.start
          [connection.create_channel, connection]
        else
          raise ConnectionError, <<~ERROR_MSG
            Must provide either connection: rabbitmq_connection or amqp_url: url.
            For example: HireFire::Macro::Bunny.job_queue_size("queue1", connection: rabbitmq_connection)
          ERROR_MSG
        end
      end
    end
  end
end
