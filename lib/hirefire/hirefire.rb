# frozen_string_literal: true

module HireFire
  extend self

  attr_writer :configuration

  def configure
    yield configuration
  end

  def configuration
    @configuration ||= Configuration.new
  end
end
