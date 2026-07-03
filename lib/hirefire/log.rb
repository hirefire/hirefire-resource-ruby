# frozen_string_literal: true

module HireFire
  module Log
    module_function

    # A user-supplied logger (or the default one writing to a closed stream) can raise. Route
    # every library log through here so a raising logger cannot escape a dispatcher/worker guard
    # and kill the loop, nor abort the host's boot from the unguarded configure -> start path.
    def safe(logger, level, message)
      logger.public_send(level, message) if logger.respond_to?(level)
    rescue
      nil
    end
  end
end
