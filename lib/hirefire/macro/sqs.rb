# encoding: utf-8

module HireFire
  module Macro
    module Sqs
      extend self

      # Counts the approximate number of jobs in the provided SQS queue.
      #
      # @example SQS Macro Usage
      #   HireFire::Macro::Sqs.queue # all queues
      #   HireFire::Macro::Sqs.queue("email") # only email queue
      #   HireFire::Macro::Sqs.queue("audio", "video") # audio and video queues
      #
      # @param [Array] queues provide one or more queue names, or none for "all".
      # @return [Integer] the number of jobs in the queue(s).
      #
      def queue(*queues)
        queues = queues.flatten.map(&:to_s)
        length = 0
        client = Aws::SQS::Client.net
        queue_urls = client.list_queues.queue_urls
        sample_url = queue_urls.first
        suffix = sample_url.split('/').last
        sample_url.slice!(suffix)
        prefix = sample_url
        queues.each do |queue_name|
          queue_url = prefix + queue_name
          attributes = client.get_queue_attributes({queue_url: queue_url, 
                                                    attribute_names: ["ApproximateNumberOfMessages"]}).attributes
          num_messages = attributes["ApproximateNumberOfMessages"].to_i
          length += num_messages
        end
        length
      end
    end
  end
end