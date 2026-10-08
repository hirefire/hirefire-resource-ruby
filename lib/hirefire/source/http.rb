# frozen_string_literal: true

module HireFire
  module Source
    class HTTP
      attr_reader :name

      def initialize(name, buffer)
        @name = name.to_s
        @buffer = buffer
      end

      def sample(request_queue_time)
        @buffer.sample(@name, Strategy::RQT, request_queue_time)
      end
    end
  end
end
