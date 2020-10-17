# frozen_string_literal: true

module HireFire
  module Macro
    module Que
      extend self

      # Queries the PostgreSQL database through Que in order to
      # count the amount of jobs in the specified queue.
      #
      # @example Queue Macro Usage
      #   HireFire::Macro::Que.queue # counts all queues.
      #   HireFire::Macro::Que.queue("email") # counts the `email` queue.
      #
      # @param [String] queue the queue name to count. (default: nil # gets all queues)
      # @return [Integer] the number of jobs in the queue(s).
      #
      def queue(*queues)
        query   = queues.empty? && base_query || base_query + " AND queue IN (#{names(queues)})"
        results = ::Que.execute(query).first
        (results[:total] || results["total"]).to_i
      end

      private

      def base_query
        return QUE_V0_QUERY if defined?(::Que::Version)
        return QUE_V1_QUERY if defined?(::Que::VERSION)
        raise "Couldn't find Que version"
      end

      def names(queues)
        queues.map { |queue| "'#{queue}'" }.join(",")
      end

      def query_const(query)
        query.gsub(/\s+/, " ").strip.freeze
      end

      QUE_V0_QUERY = query_const(<<-QUERY)
        SELECT COUNT(*) AS total
        FROM que_jobs
        WHERE run_at < NOW()
      QUERY

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
