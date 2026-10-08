# frozen_string_literal: true

module HireFire
  module Macro
    module Deprecated
      module Delayed
        module Job
          QUEUE_OPTIONS = %i[min_priority max_priority].freeze

          def queue(*queues)
            options = queues.last.is_a?(Hash) ? queues.pop : {}

            job_queue_size(*queues, **options.slice(*QUEUE_OPTIONS))
          end
        end
      end
    end
  end
end
