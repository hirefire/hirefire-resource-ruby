# frozen_string_literal: true

module HireFire
  module Macro
    module Deprecated
      module Bunny
        QUEUE_OPTIONS = %i[connection amqp_url].freeze

        def queue(*queues)
          queues.flatten!
          options = queues.last.is_a?(Hash) ? queues.pop : {}

          job_queue_size(*queues, **options.slice(*QUEUE_OPTIONS))
        end
      end
    end
  end
end
