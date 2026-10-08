# frozen_string_literal: true

module HireFire
  module Macro
    module Helpers
      module ActiveRecordConnection
        private

        def with_connection(model = nil)
          model ||= ::ActiveRecord::Base if defined?(::ActiveRecord::Base)
          return yield(nil) unless model.respond_to?(:connection_pool)

          model.connection_pool.with_connection { |connection| yield connection }
        end
      end
    end
  end
end
