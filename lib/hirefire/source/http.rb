# frozen_string_literal: true

module HireFire
  module Source
    # HTTP traffic source: samples request queue time into the +rqt+ wire strategy.
    #
    # @!attribute [r] name
    #   The process name this source reports under.
    #   @return [String]
    class HTTP
      attr_reader :name

      def initialize(name)
        @name = name.to_s
      end

      # Records a request queue-time sample (milliseconds) under the +rqt+ strategy.
      #
      # @param request_queue_time [Integer] queue time in milliseconds
      # @return [void]
      def sample(request_queue_time)
        HireFire.configuration.buffer.sample(@name, "rqt", request_queue_time)
      end
    end
  end
end
