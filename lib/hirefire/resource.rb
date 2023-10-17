# frozen_string_literal: true

require "logger"

module HireFire
  # The `Resource` module is the main entry point for integrating the
  # `hirefire-resource` gem into your application. It provides a
  # configuration interface to define how HireFire should collect,
  # serve, and dispatch metrics. These metrics are required for the
  # Heroku autoscaling decisions made by your dyno managers on
  # HireFire. Through this module, you can configure which metrics to
  # collect for web and worker dynos, and how these metrics should be
  # gathered. You can also specify a custom logger.
  #
  # This setup is usually done in an initializer within a Rails
  # application (e.g., config/initializers/hirefire.rb). For other
  # Ruby applications, the configuration should be placed in a part of
  # your codebase that is executed during application boot.
  #
  # @example Configuring HireFire to collect metrics for web (i.e. Puma) and worker (i.e. Sidekiq)
  #   HireFire::Resource.configure do |config|
  #     # Configure HireFire to use the Rails.logger
  #     config.logger = Rails.logger
  #
  #     # Configure HireFire to collect request queue time metrics and
  #     # periodically dispatch them. This matches the web dyno entry
  #     # in the Procfile.
  #     config.dyno(:web)
  #
  #     # Configure HireFire to measure Sidekiq latency across the
  #     # critical, high, default and low queues, and make these
  #     # metrics available to HireFire. This matches the worker dyno
  #     # entry in the Procfile.
  #     config.dyno(:worker) do
  #       HireFire::Macro::Sidekiq.job_queue_latency(:critical, :high, :default, :low)
  #     end
  #   end
  module Resource
    extend self

    # Yields the current configuration to a block, allowing for
    # configuration of the `hirefire-resource` gem. This method is
    # typically called from an initializer file or any other setup
    # script in your application.
    #
    # @yield [Configuration] The current configuration instance to be
    #   modified by the block.
    def configure
      yield configuration
    end

    # Accessor for the current configuration instance. If the
    # configuration has not yet been set, it initializes a new
    # Configuration instance. This method ensures that there is always
    # a configuration instance to work with.
    #
    # @return [Configuration] The current configuration instance.
    def configuration
      @configuration ||= Configuration.new
    end

    attr_writer :configuration
  end
end
