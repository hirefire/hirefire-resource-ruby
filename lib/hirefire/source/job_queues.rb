# frozen_string_literal: true

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

      def sample_job_queue(job_queue, strategy, live: nil)
        return unless job_queue

        strategy = strategy.to_s
        unless strategy == "jql" || strategy == "jqs"
          Log.safe(logger, :error, "[HireFire] Unknown job-queue strategy #{strategy.inspect} for " \
            "#{job_queue.name.inspect}. Sample dropped.")
          return
        end

        value = job_queue.sample
        return if live && !live.call

        unless valid_sample?(value)
          Log.safe(logger, :error, "[HireFire] The sampler for #{job_queue.name.inspect} returned " \
            "#{format_sample_value(value)}, expected a non-negative number. Sample dropped.")
          return
        end

        buffer.sample(job_queue.name, strategy, coerce_sample(value))
      rescue => e
        Log.safe(logger, :error, "[HireFire] The sampler for #{job_queue&.name.inspect} raised " \
          "#{e.class}: #{e.message}")
      end

      private

      def valid_sample?(value)
        value.is_a?(Numeric) && value.finite? && value >= 0
      end

      def coerce_sample(value)
        (value.is_a?(Integer) || value.is_a?(Float)) ? value : value.to_f
      end

      def format_sample_value(value)
        text = value.class.name
        preview = value.to_s
        preview = "#{preview.byteslice(0, 64)}…" if preview.bytesize > 64
        "#{text}(#{preview.inspect})"
      rescue
        value.class.name
      end

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
