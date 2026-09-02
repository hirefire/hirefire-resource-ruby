# frozen_string_literal: true

module HireFire
  module Log
    extend self

    def format_error(error)
      "#{error.class}: #{error.message}".gsub(%r{(://)([^/@\s]+)@}, '\1***@')
    end

    def safe(logger, level, message)
      logger.public_send(level, message) if logger.respond_to?(level)
    rescue
      nil
    end
  end
end
