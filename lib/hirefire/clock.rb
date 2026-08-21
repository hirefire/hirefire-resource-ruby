# frozen_string_literal: true

module HireFire
  module Clock
    extend self

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
