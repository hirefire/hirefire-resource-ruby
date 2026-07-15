# frozen_string_literal: true

module HireFire
  # Rails integration that inserts {HireFire::Middleware} at the front of the middleware stack.
  class Railtie < ::Rails::Railtie
    initializer "hirefire.insert_middleware" do |app|
      app.config.middleware.insert 0, HireFire::Middleware
    end
  end
end
