# frozen_string_literal: true

module HireFire
  module Macro
    module Deprecated
      module Bunny
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

        module Private
          extend self

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
