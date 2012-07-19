# encoding: utf-8

module HireFire
  module Resource
    extend self
    attr_accessor :dynos

    # Sets the `@dynos` instance variable to an empty Array to hold all the dyno configuration.
    #
    # Example:
    #
    #  HireFire::Resource.configure do |config|
    #    config.dyno(:worker) do
    #      # Macro or Custom logic for the :worker dyno here..
    #    end
    #  end
    #
    # @yields [HireFire::Resource] to allow for block-style configuration.
    def configure
      @dynos ||= []
      yield self
    end

    # Will be used through block-style configuration with the `configure` method.
    #
    # @param [Symbol, String] name the name of the dyno as defined in the Procfile.
    # @param [Proc] block an Integer containing the quantity calculation logic.
    def dyno(name, &block)
      @dynos << { :name => name, :quantity => block }
    end
  end
end

