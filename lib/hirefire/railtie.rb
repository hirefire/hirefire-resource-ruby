# frozen_string_literal: true

module HireFire
  class Railtie < ::Rails::Railtie
    initializer "hirefire.insert_middleware", after: :load_config_initializers do |app|
      app.config.middleware.insert 0, HireFire::Middleware
    end

    config.after_initialize do
      cfg = HireFire.configuration
      cfg.logger = ::Rails.logger if cfg.using_default_logger? && ::Rails.logger
      HireFire.boot if HireFire::Identity.resolve && !defined?(::Rails::Console)
    end
  end
end
