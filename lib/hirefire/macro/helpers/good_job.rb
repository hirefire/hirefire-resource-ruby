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
      end
    end
  end
end
