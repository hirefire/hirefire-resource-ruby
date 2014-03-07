# encoding: utf-8

module HireFire
  module DynoLists
    class Sidekiq < ::HireFire::DynoList
      def add(name, *queues, &block)
        return super if block_given?
        if name.is_a?(Hash)
          queues << name.values.first
          name = name.keys.first
        end
        dynos[name] = queues.flatten
      end

      def to_hash
        data = HireFire::Macro::Sidekiq.queue_list
        @dynos.inject({}) do |hash, (name, block)|
          if block.is_a?(Array)
            hash[name] = 0
            block.each do |queue|
              case queue
              when Symbol, String
                hash[name] += (data[queue.to_s] || 0)
              when Regexp
                data.each do |k,v|
                  hash[name] += v if k =~ queue
                end
              else
                # Should we raise here, or ignore silently?
              end
            end
          else
            hash[name] = block.call
          end
          hash
        end
      end
    end
  end
end
