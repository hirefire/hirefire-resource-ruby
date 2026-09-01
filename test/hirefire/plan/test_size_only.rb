# frozen_string_literal: true

require "test_helper"

class HireFire::Plan::SizeOnlyTest < Minitest::Test
  def setup
    super
    @helper = Object.new.extend(HireFire::Plan::Hooks).extend(HireFire::Plan::SizeOnly)
  end

  def test_supports_jqs_only
    assert @helper.supports_plan_strategy?("jqs")
    assert @helper.supports_plan_strategy?(:jqs)
    refute @helper.supports_plan_strategy?("jql")
    refute @helper.supports_plan_strategy?(:jql)
    refute @helper.supports_plan_strategy?("rpm")
  end
end
