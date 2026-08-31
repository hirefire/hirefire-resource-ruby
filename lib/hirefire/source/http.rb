# frozen_string_literal: true

module HireFire
  module Source
    class HTTP
      attr_reader :name

      def initialize(name)
        @name = name.to_s
      end

      def sample(request_queue_time)
        HireFire.configuration.buffer.sample(@name, Strategy::RQT, request_queue_time)
      end
    end
  end
end
