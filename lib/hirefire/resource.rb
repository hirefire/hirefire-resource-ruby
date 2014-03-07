# encoding: utf-8

module HireFire
  module Resource
    extend self


    # Sets the `@dynos` instance variable to an empty Array to hold all the dyno configuration.
    #
    # @example Resource Configuration
    #   HireFire::Resource.configure do |config|
    #     config.dyno(:worker) do
    #       # Macro or Custom logic for the :worker dyno here..
    #     end
    #   end
    #
    # @yield [HireFire::Resource] to allow for block-style configuration.
    #
    def configure
      @dynos ||= DynoList.new
      yield self
    end

    # @return [HireFire::DynoList] The configured dyno list
    #
    def dynos
      @dynos ||= DynoList.new
    end

    # @param [HireFire::DynoList,Object] dyno_list the DynoList class or an instance of it. You can
    #   use anything instance that responds to {#to_hash}
    def dynos=(dyno_list)
      dyno_list = dyno_list.new if dyno_list.is_a?(Class)
      if dyno_list.respond_to?(:to_hash)
        @dynos = dyno_list
      else
        raise ArgumentError.new('Must be a class/instance of HireFire::DynoList or another class that responds to #to_hash')
      end
    end

    # Will be used through block-style configuration with the `configure` method.
    #
    # @param [Symbol, String] name the name of the dyno as defined in the Procfile.
    # @param [Array] args additional args, potentially used by the current dyno list
    # @param [Proc] block an Integer containing the quantity calculation logic.
    #
    def dyno(name, *args, &block)
      dynos.add(name, *args, &block)
    end
  end
end

