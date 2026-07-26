# frozen_string_literal: true

module HireFire
  # Rails integration that inserts {HireFire::Middleware} and starts always-on collectors when a
  # token is present.
  class Railtie < ::Rails::Railtie
    initializer "hirefire.insert_middleware" do |app|
      app.config.middleware.insert 0, HireFire::Middleware
    end

    config.after_initialize do
      HireFire.boot if HireFire.configuration.token
    end
  end
end
