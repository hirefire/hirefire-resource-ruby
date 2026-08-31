# frozen_string_literal: true

require "hirefire/macro/helpers/good_job"

module HireFire
  module Macro
    module Deprecated
      module GoodJob
        include HireFire::Macro::Helpers::GoodJob

        def queue(*queues)
          scope = good_job_class.only_scheduled.unfinished
          scope = scope.where(queue_name: queues) if queues.any?
          scope.count
        end
      end
    end
  end
end
