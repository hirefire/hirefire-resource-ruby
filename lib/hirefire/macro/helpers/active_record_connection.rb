# frozen_string_literal: true

module HireFire
  module Macro
    module Helpers
      # Optional Active Record pool checkout for macros that query via AR.
      #
      # Safe outside Rails: when Active Record (or its connection pool) is absent,
      # the block runs with no pool interaction. Use from SQL-backed macros so
      # long-lived HireFire sampler threads check connections back in.
      module ActiveRecordConnection
        private

        def with_connection
          if defined?(::ActiveRecord::Base) &&
              ::ActiveRecord::Base.respond_to?(:connection_pool)
            ::ActiveRecord::Base.connection_pool.with_connection { yield }
          else
            yield
          end
        end
      end
    end
  end
end
