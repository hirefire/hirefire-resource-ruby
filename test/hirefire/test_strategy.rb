# frozen_string_literal: true

require "test_helper"

class HireFire::StrategyTest < Minitest::Test
  def test_rqt_accepts_string_and_symbol
    assert HireFire::Strategy.rqt?("rqt")
    assert HireFire::Strategy.rqt?(:rqt)
  end

  def test_rqt_rejects_other_strategies
    refute HireFire::Strategy.rqt?("jql")
    refute HireFire::Strategy.rqt?(:jqs)
    refute HireFire::Strategy.rqt?(nil)
  end
end
