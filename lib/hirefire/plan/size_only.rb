# frozen_string_literal: true

module HireFire
  module Plan
    module SizeOnly
      def supports_plan_strategy?(strategy)
        strategy.to_s == "jqs"
      end
    end
  end
end
