# encoding: utf-8

module HireFire
  module Macro
    module Que
      QUERY =  %{
SELECT count(*)                                                          AS total,
       count(locks.job_id)                                               AS running,
       coalesce(sum((error_count > 0 AND locks.job_id IS NULL)::int), 0) AS failing,
       coalesce(sum((error_count = 0 AND locks.job_id IS NULL)::int), 0) AS scheduled
FROM que_jobs LEFT JOIN (
  SELECT (classid::bigint << 32) + objid::bigint AS job_id
  FROM pg_locks WHERE locktype = 'advisory'
) locks USING (job_id) }.freeze

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
      def queue(queue = nil)
        query = queue ? "#{QUERY} WHERE queue = '#{queue}'" : QUERY
        results = ::Que.execute(query).first
        results["total"].to_i - results["failing"].to_i
      end
    end
  end
end
