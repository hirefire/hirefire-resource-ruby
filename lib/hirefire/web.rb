# frozen_string_literal: true

module HireFire
  class Web
    attr_reader :name

    def initialize(name)
      @name = name.to_s
    end

    def sample(request_queue_time)
      HireFire.configuration.buffer.sample_web(request_queue_time)
    end
  end
end
