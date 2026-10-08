# frozen_string_literal: true

module HireFire
  module Macro
    module Helpers
      module GoodJob
        private

        def good_job_class
          (::GoodJob::VERSION.to_i >= 4) ? ::GoodJob::Job : ::GoodJob::Execution
        end

        def error_event_supported?
          good_job_class.column_names.include?("error_event")
        end

        def lock_type_supported?
          good_job_class.column_names.include?("lock_type")
        end

        def discarded_enum
          5
        end
      end
    end
  end
end
