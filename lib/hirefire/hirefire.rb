# frozen_string_literal: true

module HireFire
  extend self

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
