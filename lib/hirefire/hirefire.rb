# frozen_string_literal: true

require "logger"

# The `HireFire` module serves as the primary interface for integrating the `hirefire-resource` gem
# into your application. It offers a configuration interface to specify how metrics (such as job
# queue latency and job queue size) should be collected, served, and dispatched for web and worker
# dynos. These metrics enables making autoscaling decisions for Heroku dynos. A custom logger can
# also be configured.
#
# Configuration is typically done in an initializer in Rails (e.g., config/initializers/hirefire.rb)
# or during the application boot process in other Ruby applications.
#
# @example Configuring HireFire for web and worker dyno metrics
#   HireFire.configure do |config|
#     config.logger = Rails.logger  # Set a custom logger
#     config.dyno(:web)             # Configure web dyno metrics
#     config.dyno(:worker) do       # Configure worker dyno metrics
#       HireFire::Macro::Sidekiq.job_queue_latency(:critical, :high, :default, :low)
#     end
#   end
module HireFire
  extend self

  # Yields the singleton configuration instance to a block for customization.  This method is
  # typically invoked from an initializer or setup script.
  #
  # @yield [Configuration] The singleton configuration instance for modification.
  def configure
    yield configuration
  end

  # Provides access to the singleton configuration instance. Initializes a new Configuration
  # instance if not already set, ensuring a consistent configuration state.
  #
  # @return [Configuration] The singleton configuration instance.
  def configuration
    @configuration ||= Configuration.new
  end

  attr_writer :configuration
end
