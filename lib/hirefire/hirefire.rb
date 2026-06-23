# frozen_string_literal: true

module HireFire
  extend self

  # Configures HireFire and starts reporting metrics. Yields the configuration object so each
  # process can declare what it tracks (see {HireFire::Configuration#service} and
  # {HireFire::Configuration#dyno}).
  #
  # After the block runs, the dispatcher starts automatically when a token is present, set in
  # code (`config.token = ...`) or via the `HIREFIRE_TOKEN` environment variable. With no token
  # the app runs normally and reports nothing, so it is safe to leave configured in every
  # environment.
  #
  # @yieldparam config [HireFire::Configuration] the configuration to declare processes on.
  # @return [HireFire::Configuration] the configuration.
  # @example
  #   HireFire.configure do |config|
  #     config.service(:web, tracking: :http)
  #     config.service(:worker) { HireFire::Macro::Sidekiq.job_queue_latency(:default) }
  #     config.service(:encoder, tracking: :cpu)
  #   end
  def configure
    yield configuration
    configuration.dispatcher.start if configuration.token
    configuration
  end

  def configuration
    @configuration ||= Configuration.new
  end

  def reset
    @configuration&.dispatcher&.stop
    @configuration = nil
  end
end
