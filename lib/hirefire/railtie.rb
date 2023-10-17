# frozen_string_literal: true

module HireFire
  class Railtie < ::Rails::Railtie
    initializer "hirefire.insert_middleware" do |app|
      app.config.middleware.insert 0, HireFire::Middleware
    end
  end
end
