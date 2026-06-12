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

        [
          :interrupted,
          :unhandled,
          :handled,
          :retried,
          :retry_stopped,
          :discarded
        ].each_with_index do |event, index|
          define_method(:"#{event}_enum") { index }
        end
      end
    end
  end
end
