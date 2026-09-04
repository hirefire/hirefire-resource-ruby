# frozen_string_literal: true

require_relative "../sample"

module HireFire
  module Source
    class JobQueues
      include Enumerable

      def initialize(configuration = nil)
        @configuration = configuration
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

      def sample_job_queue(job_queue, strategy, live: nil, name: nil)
        return unless job_queue

        report_name = (name.nil? || name.to_s.strip.empty?) ? job_queue.name : name.to_s.strip
        strategy = strategy.to_s
        unless strategy == "jql" || strategy == "jqs"
          Log.safe(logger, :error, "[HireFire] Unknown job-queue strategy #{strategy.inspect} for " \
            "#{report_name.inspect}. Sample dropped.")
          return
        end

        value = job_queue.sample
        return if live && !live.call

        unless HireFire::Sample.valid?(value)
          Log.safe(logger, :error, "[HireFire] The sampler for #{report_name.inspect} returned " \
            "#{HireFire::Sample.format(value)}, expected a non-negative number. Sample dropped.")
          return
        end

        buffer.sample(report_name, strategy, HireFire::Sample.coerce(value))
      rescue => e
        Log.safe(logger, :error, "[HireFire] The sampler for #{report_name.inspect} raised " \
          "#{Log.format_error(e)}")
      end

      private

      def buffer
        configuration.buffer
      end

      def logger
        configuration.logger
      end

      def configuration
        @configuration || HireFire.configuration
      end
    end
  end
end
