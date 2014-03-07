# encoding: utf-8

module HireFire
  module DynoLists
    class Sidekiq < ::HireFire::DynoList

      # Used to add a dyno to the list of dynos
      #
      # You can call this in a few ways:
      #
      #   list.add(name: %w(queue1 queue2))
      #   list.add(:name, %w(queue1 queue2))
      #   list.add(:name, /^queue[12]$/)
      #   list.add(:name => [/^queue1$/, /^queue2$/])
      #   list.add(:name) do
      #     HireFire::Macro::Sidekiq.queue(%w(queue1 queue2))
      #   end
      #
      # Would all give the same results, though the last one
      # would require additional calls to sidekiq to generate the
      # counts. Queues listed as strings or matched by regexes
      # only require a single call to sidekiq, so generally try
      # to avoid the block form if possible.
      #
      # @param [Symbol, String, Hash] name the name of the dyno as defined in the Procfile. If
      #   a hash is passed in, the first key is used as the name, and then
      #   the first value is set as the second argument
      # @param [Array<String>,Array<Regexp>,Regexp,String] queues list of queue names or regexes to
      #   match queue names against dynamically
      # @param [Proc] block an Integer containing the quantity calculation logic.
      #
      def add(name, *queues, &block)
        return super if block_given?
        if name.is_a?(Hash)
          queues << name.values.first
          name = name.keys.first
        end
        dynos[name] = queues.flatten
      end

      # Generates a hash by calling {HireFire::Macro::Sidekiq.queue_list} and
      # then matching each configured dyno (added with {#add}) against the
      # list of quantities for queues sidekiq provided stats for.
      #
      # @return [Hash] the renderable list of names/quatities
      #
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
