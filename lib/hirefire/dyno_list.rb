# encoding: utf-8

module HireFire
  class DynoList
    # @return [Hash] The configured dynos.
    attr_accessor :dynos

    def initialize
      @dynos ||= {}
    end

    # Used to add a dyno to the list of dynos
    #
    # @param [Symbol, String] name the name of the dyno as defined in the Procfile.
    # @param [Proc] block an Integer containing the quantity calculation logic.
    #
    def add(name, &block)
      @dynos[name] = block
    end

    # Generates a hash by calling the configured block for each dyno in {#dynos}
    #
    # @return [Hash] the return able list of names/quatities
    #
    def to_hash
      @dynos.inject({}) do |hash, (name, block)|
        hash[name] = block.call
        hash
      end
    end

    # Generates a json string representing the data from calling {#to_hash}
    #
    # @return [String] the json representation of data from {#to_hash}
    #
    def to_json
      HireFire::JsonFormatter.to_json(to_hash)
    end
  end
end
