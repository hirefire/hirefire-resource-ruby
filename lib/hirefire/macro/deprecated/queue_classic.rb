# frozen_string_literal: true

module HireFire
  module Macro
    module Deprecated
      module QC
        def queue(queue = "default")
          job_queue_size(queue)
        end
      end
    end
  end
end
