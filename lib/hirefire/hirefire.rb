# frozen_string_literal: true

require "logger"

# `HireFire` is the primary module of the hirefire-resource gem.
#
# The gem is configured through this module. In Rails, configuration is typically done in an
# initializer (i.e. config/initializers/hirefire.rb). For other Ruby applications, ensure that the
# configuration is loaded at application startup.
#
# @example Configuration for autoscaling Rails (web) + Sidekiq (worker) dynos
#   HireFire.configure do |config|
#     config.logger = Rails.logger  # Use to Rails.logger
#     config.dyno(:web)             # Capture web dyno metrics
#     config.dyno(:worker) do       # Provide worker dyno metrics
#       HireFire::Macro::Sidekiq.job_queue_latency(:default)
#     end
#   end
module HireFire
  extend self

  # Yields the singleton configuration instance to a block for customization. This method is
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
