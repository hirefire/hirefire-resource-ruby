# frozen_string_literal: true

module HireFire
  module Macro
    module Deprecated
      module Resque
        def queue(*queues)
          job_queue_size(*queues)
        end
      end
    end
  end
end
