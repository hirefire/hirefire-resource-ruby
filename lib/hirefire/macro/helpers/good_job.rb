module HireFire
  module Macro
    module Helpers
      module GoodJob
        def self.included(base)
          base.send(:private, :good_job_class)
        end

        def good_job_class
          if Gem::Version.new(::GoodJob::VERSION) >= Gem::Version.new("4.0.0")
            ::GoodJob::Job
          else
            ::GoodJob::Execution
          end
        end

        # The error_event column arrived in GoodJob 3.16, so a version check is
        # wrong for 3.0-3.15 and for gem upgrades whose migration has not run.
        # Check the live schema instead.
        def error_event_supported?
          good_job_class.column_names.include?("error_event")
        end

        # GoodJob's error_event enum integer values (interrupted=0, unhandled=1,
        # handled=2, retried=3, retry_stopped=4, discarded=5). Only the two consulted
        # are defined: discarded gates queue metrics, retried is asserted in tests.
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
