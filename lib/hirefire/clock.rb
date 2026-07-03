# frozen_string_literal: true

module HireFire
  module Clock
    module_function

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
