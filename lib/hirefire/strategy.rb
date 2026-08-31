# frozen_string_literal: true

module HireFire
  module Strategy
    extend self

    RQT = "rqt"

    def rqt?(strategy)
      strategy.to_s == RQT
    end
  end
end
