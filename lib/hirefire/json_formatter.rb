# encoding: utf-8

module HireFire
  module JsonFormatter
    extend self

    # Generates a json string representing the queue_list passed in
    #
    # @param [Hash] queue_list list of queue names and quantities.
    # @return [String] the json representation of data from {#to_hash}
    #
    def to_json(queue_list)
      dyno_data = queue_list.inject(String.new) do |json, (name, quantity)|
        json << %|,{"name":"#{name}","quantity":#{quantity || "null"}}|; json
      end

      "[#{dyno_data.sub(",","")}]"
    end
  end
end
