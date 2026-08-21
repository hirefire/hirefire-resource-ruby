# frozen_string_literal: true

module HireFire
  module Source
    class JobQueue
      attr_reader :name

      def initialize(name, &sampler)
        @name = name.to_s
        @sampler = sampler
      end

      def sample
        @sampler.call
      end
    end
  end
end
