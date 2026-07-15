# frozen_string_literal: true

module HireFire
  # HTTP request queue-time collector for a declared http process.
  #
  # @!attribute [r] name
  #   The process name this collector reports under.
  #   @return [String]
  class Web
    attr_reader :name

    def initialize(name)
      @name = name.to_s
    end

    # Records a request queue-time sample (milliseconds) into the buffer.
    #
    # @param request_queue_time [Integer] queue time in milliseconds
    # @return [void]
    def sample(request_queue_time)
      HireFire.configuration.buffer.sample_web(request_queue_time)
    end
  end
end
