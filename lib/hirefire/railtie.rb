# frozen_string_literal: true

module HireFire
  # The `Railtie` class provides Rails-specific integration for
  # HireFire.
  #
  # `Railtie` is a core component of the Rails framework that allows
  # extensions to be hooked into Rails applications.  In the context
  # of the hirefire-resource gem, the `Railtie` ensures that the
  # `HireFire::Middleware` is automatically added to the middleware
  # stack of a Rails application during the application's
  # initialization process.
  #
  # By including this Railtie, HireFire provides out-of-the-box
  # compatibility with Rails applications without requiring developers
  # to manually insert the middleware into the application's
  # middleware stack.
  #
  # @see HireFire::Middleware For details on what the middleware does
  #   within the application.
  class Railtie < ::Rails::Railtie
    # Initializes and adds the HireFire middleware to the Rails
    # application middleware stack.
    #
    # By inserting the middleware at the top of the stack (`insert 0`),
    # we ensure that the `HireFire::Middleware` processes the request
    # as early as possible.
    #
    # @param app [Rails::Application] The current Rails application instance.
    initializer "hirefire.add_middleware" do |app|
      app.config.middleware.insert 0, HireFire::Middleware
    end
  end
end
