# frozen_string_literal: true

module HireFire
  module Macro
    module Bunny
      extend self

      # Returns the job quantity for the provided queue(s).
      #
      # @example Bunny Macro Usage
      #
      #   # all queues using existing RabbitMQ connection.
      #   HireFire::Macro::Bunny.queue("queue1", "queue2", :connection => connection)
      #
      #   # all queues using new RabbitMQ connection.
      #   HireFire::Macro::Bunny.queue("queue1", "queue2", :amqp_url => url)
      #
      #   # all non-durable queues using new RabbitMQ connection.
      #   HireFire::Macro::Bunny.queue("queue1", "queue2", :amqp_url => url, :durable => false)
      #
      # @param [Array] queues provide one or more queue names, or none for "all".
      #   Last argument can pass in a Hash containing :connection => rabbitmq_connection or :amqp => :rabbitmq_url
      # @return [Integer] the number of jobs in the queue(s).
      #
      def queue(*queues)
        require "bunny"

        queues.flatten!

        if queues.last.is_a?(Hash)
          options = queues.pop
        else
          options = {}
        end

        if options[:durable].nil?
          options[:durable] = true
        end

        if options[:connection]
          connection = options[:connection]

          channel = nil
          begin
            channel = connection.create_channel
            return count_messages(channel, queues, options)
          ensure
            if channel
              channel.close
            end
          end
        elsif options[:amqp_url]
          connection = ::Bunny.new(options[:amqp_url])
          begin
            connection.start
            channel = connection.create_channel
            return count_messages(channel, queues, options)
          ensure
            if channel
              channel.close
            end

            connection.close
          end
        else
          raise %{Must pass in :connection => rabbitmq_connection or :amqp_url => url\n} +
                  %{For example: HireFire::Macro::Bunny.queue("queue1", :connection => rabbitmq_connection}
        end
      end

      def count_messages(channel, queue_names, options)
        queue_names.inject(0) do |sum, queue_name|
          if options.key?(:'x-max-priority')
            queue = channel.queue(queue_name, :durable   => options[:durable],
                                              :arguments => {"x-max-priority" => options[:'x-max-priority']})
          else
            queue = channel.queue(queue_name, :durable => options[:durable])
          end
          sum + queue.message_count
        end
      end
    end
  end
end
