# frozen_string_literal: true

module HireFire
  module Macro
    module Helpers
      module GoodJob
        def self.included(base)
          base.send(:private, :good_job_class)
        end

        def self.extended(base)
          privatize_helpers(base)
        end

        def self.privatize_helpers(base)
          base.send(
            :private_class_method,
            :good_job_class,
            :error_event_supported?,
            :retried_enum,
            :discarded_enum
          )
        end

        def good_job_class
          if Gem::Version.new(::GoodJob::VERSION) >= Gem::Version.new("4.0.0")
            ::GoodJob::Job
          else
            ::GoodJob::Execution
          end
        end

        def error_event_supported?
          good_job_class.column_names.include?("error_event")
        end

        def retried_enum
          3
        end

        def discarded_enum
          5
        end
      end
    end
  end
end
