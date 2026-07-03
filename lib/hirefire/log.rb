# frozen_string_literal: true

module HireFire
  module Log
    module_function

    def safe(logger, level, message)
      logger.public_send(level, message) if logger.respond_to?(level)
    rescue
      nil
    end
  end
end
