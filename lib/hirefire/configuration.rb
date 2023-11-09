# frozen_string_literal: true

module HireFire
  class Configuration
    # Raised when an invalid dyno name is provided. This error indicates that the provided
    # name does not conform to the Procfile naming restrictions.
    class InvalidDynoName < StandardError; end

    # Raised when a required block is not provided for a worker dyno configuration.
    # Worker dynos must have a block that defines how to measure the job queue metric.
    class MissingDynoBlock < StandardError; end

    # Retrieves the Web instance, which is HireFire's dispatcher for web metrics.
    # This instance is responsible for collecting and dispatching web metrics to
    # HireFire's servers.
    #
    # @return [HireFire::Web, nil] The Web instance responsible for collecting and dispatching web metrics.
    attr_reader :web

    # Retrieves the configured worker dyno configurations as an array of Worker instances.
    # Each Worker instance matches a worker dyno name from the Procfile and contains a block
    # of code that defines how to measure the job queue metric.
    #
    # @return [Array<HireFire::Worker>] An array of Worker instances, each configured with a
    #                                   dyno name and a block defining its metric measurement logic.
    attr_reader :workers

    def initialize
      @web = nil
      @workers = []
    end

    # Retrieves the logger instance, defaulting to `$stdout`. The default logger outputs to
    # the standard output, which is typically visible in most runtime environments, ensuring
    # that logs are not lost if a custom logger is not set.
    #
    # @return [Logger] The logger instance, defaulting to `$stdout` if not otherwise configured.
    def logger
      @logger ||= Logger.new($stdout)
    end

    attr_writer :logger

    # Checks whether logging of queue metrics is enabled. This is required for the
    # Web.Logplex.QueueTime strategy, which uses the logged queue metrics for analysis.
    #
    # @return [Boolean] `true` if logging of queue metrics is enabled, `false` otherwise.
    def log_queue_metrics
      @log_queue_metrics ||= false
    end

    attr_writer :log_queue_metrics

    # Configures Web and Worker objects.
    #
    # The block is ignored for the Web object as it is not used for
    # collecting web metrics.
    #
    # The block is required for Worker objects as it should return the
    # job queue latency or job queue size metric.
    #
    # @param name [Symbol, String] The name of the dyno as declared in the Procfile.
    # @param block [Proc] Required for worker dynos and returns an integer representing
    #   the job queue latency or job queue size metric. Ignored when name is :web.
    # @raise [InvalidDynoName] If the dyno name is invalid according to Procfile naming restrictions.
    # @raise [MissingDynoBlock] If a required block is not provided for a worker dyno.
    # @example Configuring HireFire to dispatch web dyno metrics
    #   HireFire::Resource.configure do |config|
    #     config.dyno(:web)
    #   end
    # @example Configuring HireFire to measure and provide job queue metrics for a worker dyno
    #   HireFire::Resource.configure do |config|
    #     config.dyno(:worker) do
    #       HireFire::Macro::Sidekiq.job_queue_latency(:critical, :high, :default, :low)
    #     end
    #   end
    def dyno(name, &block)
      if name.to_s == "web"
        @web = Web.new
      elsif name.to_s.match?(/\A[a-zA-Z][a-zA-Z0-9_]{0,29}\z/)
        if block
          @workers << Worker.new(name, &block)
        else
          raise MissingDynoBlock,
            "Missing block for #{self.class}#dyno(#{name}, &block). " \
            "Ensure that you provide a block of code that returns the queue metric."
        end
      else
        raise InvalidDynoName,
          "Invalid name for #{self.class}#dyno(#{name}, &block). " \
          "Ensure it matches the Procfile process name (i.e. web, worker)."
      end
    end
  end
end
