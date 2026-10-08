# frozen_string_literal: true

module HireFire
  module Source
    class JobQueues
      include Enumerable

      def initialize
        @job_queues = []
      end

      def <<(job_queue)
        @job_queues << job_queue
      end

      def find_by_name(name)
        needle = name.to_s
        @job_queues.find { |job_queue| job_queue.name.casecmp?(needle) }
      end

      def each(&block)
        @job_queues.each(&block)
      end
    end
  end
end
