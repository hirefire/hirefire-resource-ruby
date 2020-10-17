module HireFire
  module Resource
    extend self

    # This option, when enabled, will write queue metrics to $stdout,
    # and is only required when using the Web.Logplex.QueueTime strategy.
    #
    # @param [Boolean] Whether or not the queue metrics should be logged.
    #
    attr_writer :log_queue_metrics

    # @return [Boolean] True if the queue metrics option is enabled.
    #
    def log_queue_metrics
      @log_queue_metrics ||= false
    end

    # @return [Array] The configured dynos.
    #
    def dynos
      @dynos ||= []
    end

    # Configures HireFire::Resource.
    #
    # @example Resource Configuration
    #   HireFire::Resource.configure do |config|
    #     config.log_queue_metrics = true # disabled by default
    #     config.dyno(:worker) do
    #       # Macro or Custom logic for the :worker dyno here..
    #     end
    #   end
    #
    # @yield [HireFire::Resource] to allow for block-style configuration.
    #
    def configure
      yield self
    end

    # Will be used through block-style configuration with the `configure` method.
    #
    # @param [Symbol, String] name the name of the dyno as defined in the Procfile.
    # @param [Proc] block an Integer containing the quantity calculation logic.
    #
    def dyno(name, &block)
      dynos << { :name => name, :quantity => block }
    end
  end
end
