# frozen_string_literal: true

module HireFire
  module Macro
    module Deprecated
      # Provides backward compatibility with the deprecated Que macro.
      # For new implementations, refer to {HireFire::Macro::Que}.
      module Que
        # Retrieves the total number of jobs in the specified queue(s) using Que.
        #
        # This method queries the PostgreSQL database through Que. It can count jobs
        # in specified queues or all queues if no specific queue is provided.
        # The method determines the base query depending on the Que version detected.
        #
        # @param queues [Array<String>] The names of the queues to count.
        #   Pass an empty array or no arguments to count jobs in all queues.
        # @return [Integer] Total number of jobs in the specified queues.
        # @example Counting jobs in all queues
        #   HireFire::Macro::Que.queue
        # @example Counting jobs in the "default" queue
        #   HireFire::Macro::Que.queue("default")
        def queue(*queues)
          query = queues.empty? ? Private.base_query : "#{Private.base_query} AND queue IN (#{Private.names(queues)})"
          results = ::Que.execute(query).first
          (results[:total] || results["total"]).to_i
        end

        # @!visibility private
        module Private
          extend self

          # Determines the base query to use for counting jobs, depending on the Que version.
          #
          # @return [String] The base SQL query string.
          def base_query
            return QUE_V0_QUERY if defined?(::Que::Version)
            return QUE_V1_QUERY if defined?(::Que::VERSION)
            raise "Couldn't find Que version"
          end

          # Formats queue names for SQL query.
          #
          # @param queues [Array<String>] The names of the queues.
          # @return [String] Formatted queue names for SQL IN clause.
          def names(queues)
            queues.map { |queue| "'#{queue}'" }.join(",")
          end

          # Formats and freezes a SQL query string for use.
          #
          # @param query [String] The raw SQL query string.
          # @return [String] The formatted and frozen SQL query string.
          def query_const(query)
            query.gsub(/\s+/, " ").strip.freeze
          end

          # SQL query string for Que version 0.
          QUE_V0_QUERY = query_const(<<-QUERY)
            SELECT COUNT(*) AS total
            FROM que_jobs
            WHERE run_at < NOW()
          QUERY

          # SQL query string for Que version 1.
          QUE_V1_QUERY = query_const(<<-QUERY)
            SELECT COUNT(*) AS total
            FROM que_jobs
            WHERE finished_at IS NULL
            AND expired_at IS NULL
            AND run_at <= NOW()
          QUERY
        end
      end
    end
  end
end
