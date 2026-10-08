# frozen_string_literal: true

module HireFire
  module Macro
    module Deprecated
      module Sidekiq
        QUEUE_OPTIONS = %i[skip_scheduled skip_retries skip_working max_scheduled].freeze

        def latency(queue = "default")
          job_queue_latency(queue)
        end

        def queue(*args)
          args.flatten!
          options = args.last.is_a?(Hash) ? args.pop : {}

          job_queue_size(*args, **options.slice(*QUEUE_OPTIONS))
        end
      end
    end
  end
end
