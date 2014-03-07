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
      @dynos = coerce_dyno_list(dyno_list)
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

    private
    # @private
    # Converts a symbol or class to a dyno list and verifies we can call
    # #to_hash on it
    #
    # @param [HireFire::DynoList,Object] dyno_list the DynoList class or an instance of it. You can
    #   use anything instance that responds to {#to_hash}
    def coerce_dyno_list(dyno_list)
      return_val = case dyno_list
                   when Class
                     dyno_list.new
                   when :sidekiq
                     HireFire::DynoLists::Sidekiq.new
                   else
                     dyno_list
                   end
      unless return_val.respond_to?(:to_hash)
        raise ArgumentError.new('Must be a class/instance of HireFire::DynoList or another class that responds to #to_hash')
      end
      return return_val
    end

  end
end

