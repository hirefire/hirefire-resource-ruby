# frozen_string_literal: true

module HireFire
  # Rails integration that inserts {HireFire::Middleware} and starts always-on collectors when a
  # token is present.
  class Railtie < ::Rails::Railtie
    initializer "hirefire.insert_middleware", after: :load_config_initializers do |app|
      next if middleware_already_queued?(app)

      app.config.middleware.insert 0, HireFire::Middleware
    end

    config.after_initialize do
      cfg = HireFire.configuration
      cfg.logger = ::Rails.logger if cfg.using_default_logger? && defined?(::Rails) && ::Rails.logger
      HireFire.boot if cfg.token
    end

    private

    # +config.middleware+ is a MiddlewareStackProxy during initializers: operations are
    # deferred and there is no live +#middlewares+ list. Inspect the proxy's operations
    # (and the built stack when available) for an existing HireFire::Middleware insert/use.
    def middleware_already_queued?(app)
      stack = app.config.middleware
      return true if operations_include_hirefire?(stack)
      return true if built_stack_includes_hirefire?(app)

      false
    rescue
      false
    end

    def operations_include_hirefire?(stack)
      ops = stack.instance_variable_get(:@operations) ||
        stack.instance_variable_get(:@middleware) ||
        []
      Array(ops).any? { |op| operation_targets_hirefire?(op) }
    end

    def operation_targets_hirefire?(op)
      args = case op
      when Array
        op
      when Proc
        return false
      else
        return false unless op.respond_to?(:args) || op.respond_to?(:[])

        op.respond_to?(:args) ? op.args : op
      end
      Array(args).flatten.any? { |item| hirefire_middleware_class?(item) }
    rescue
      false
    end

    def built_stack_includes_hirefire?(app)
      return false unless app.respond_to?(:middleware)

      built = app.middleware
      return false unless built.respond_to?(:middlewares)

      built.middlewares.any? { |entry| hirefire_middleware_class?(entry.respond_to?(:klass) ? entry.klass : entry) }
    end

    def hirefire_middleware_class?(item)
      item == HireFire::Middleware || item.to_s == "HireFire::Middleware"
    end
  end
end
