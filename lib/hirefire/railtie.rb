# encoding: utf-8

module HireFire
  class Railtie < ::Rails::Railtie
    initializer "hirefire.add_middleware" do |app|
      app.config.middleware.insert_before "Rack::ETag", "HireFire::Middleware"
    end
  end
end
