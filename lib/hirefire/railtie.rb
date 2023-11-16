# frozen_string_literal: true

module HireFire
  # The `HireFire::Railtie` class integrates the `hirefire-resource` gem with Rails applications.
  # It does this by inserting the `HireFire::Middleware` at the beginning of the Rails middleware
  # stack. This positioning at the very start (or as early as possible) is crucial for accurately
  # capturing request queue time metrics.
  #
  # @see HireFire::Middleware For detailed information about the middleware's role in measuring and
  #   optimizing request queue times.
  class Railtie < ::Rails::Railtie
    initializer "hirefire.add_middleware" do |app|
      app.config.middleware.insert 0, HireFire::Middleware
    end
  end
end
