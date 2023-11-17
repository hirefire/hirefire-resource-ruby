# frozen_string_literal: true

module HireFire
  extend self

  def configure
    yield configuration
  end

  def configuration
    @configuration ||= Configuration.new
  end

  attr_writer :configuration
end
