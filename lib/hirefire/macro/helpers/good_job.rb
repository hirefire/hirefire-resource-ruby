# frozen_string_literal: true

module HireFire
  module Macro
    module Helpers
      module GoodJob
        def self.extended(base)
          privatize_helpers(base)
        end

        def self.privatize_helpers(base)
          base.send(
            :private_class_method,
            :good_job_class,
            :error_event_supported?,
            :lock_type_supported?,
            :discarded_enum
          )
        end

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
