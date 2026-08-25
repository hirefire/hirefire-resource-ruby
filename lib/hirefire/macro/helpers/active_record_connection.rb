# frozen_string_literal: true

module HireFire
  module Macro
    module Helpers
      module ActiveRecordConnection
        private

        def with_connection
          if defined?(::ActiveRecord::Base) &&
              ::ActiveRecord::Base.respond_to?(:connection_pool)
            ::ActiveRecord::Base.connection_pool.with_connection { |connection| yield connection }
          else
            yield nil
          end
        end
      end
    end
  end
end
