# frozen_string_literal: true

module HireFire
  module Macro
    module Deprecated
      # Provides backward compatibility with the deprecated Bunny macro.
      # For new implementations, refer to {HireFire::Macro::Bunny}.
      module Bunny
        # Retrieves the total number of jobs in the specified queue(s).
        #
        # This method allows querying multiple queues and supports both existing and new RabbitMQ
        # connections. By default, queues are considered durable unless specified otherwise.
        #
        # @param queues [Array<String, Symbol>] Queue names to query.
        #   The last argument can be a Hash with either :connection or :amqp_url.
        # @option queues [Bunny::Session, nil] :connection An existing RabbitMQ connection.
        # @option queues [String, nil] :amqp_url RabbitMQ URL for initializing a new connection.
        # @option queues [Boolean] :durable (true) Set to false for non-durable queues.
        # @option queues [Integer, nil] :"x-max-priority" (nil) The maximum priority level for the queue.
        #   If specified, it overrides the default priority settings for the queue.
        # @return [Integer] Total number of jobs in the specified queues.
        # @raise [ArgumentError] Raises an error if neither :connection nor :amqp_url are provided.
        # @example Querying the default queue using an existing RabbitMQ connection
        #   HireFire::Macro::Bunny.queue("default", connection: connection)
        # @example Querying the default queue using a new RabbitMQ connection
        #   HireFire::Macro::Bunny.queue("default", amqp_url: url)
        # @example Querying the "default" and "critical" non-durable queues
        #   HireFire::Macro::Bunny.queue("default", "critical", amqp_url: url, durable: false)
        # @example Querying a priority queue
        #   HireFire::Macro::Bunny.queue("priority_queue", connection: connection, "x-max-priority": 10)
        def queue(*queues)
          require "bunny"

          queues.flatten!
          options = queues.last.is_a?(Hash) ? queues.pop : {}
          options[:durable] = true if options[:durable].nil?

          if options[:connection]
            connection = options[:connection]
            channel = nil
            begin
              channel = connection.create_channel
              Private.count_messages(channel, queues, options)
            ensure
              channel&.close
            end
          elsif options[:amqp_url]
            connection = ::Bunny.new(options[:amqp_url])
            begin
              connection.start
              channel = connection.create_channel
              Private.count_messages(channel, queues, options)
            ensure
              channel&.close
              connection.close
            end
          else
            raise ArgumentError, "Must pass either :connection => rabbitmq_connection or :amqp_url => url." \
                                 "For example: HireFire::Macro::Bunny.queue(\"queue1\", connection: rabbitmq_connection)"
          end
        end

        # @!visibility private
        module Private
          extend self

          # Counts the number of messages in the specified queues.
          #
          # @param channel [Bunny::Channel] The channel to interact with RabbitMQ.
          # @param queues [Array<String, Symbol>] The names of the queues to count messages from.
          # @param options [Hash] The options for the queues, including durability and priority settings.
          # @return [Integer] The total number of messages across all specified queues.
          def count_messages(channel, queues, options)
            queues.inject(0) do |sum, queue|
              queue_options = {durable: options[:durable]}
              queue_options[:arguments] = {"x-max-priority" => options[:"x-max-priority"]} if options.key?(:"x-max-priority")
              queue = channel.queue(queue.to_s, **queue_options)
              sum + queue.message_count
            end
          end
        end
      end
    end
  end
end
