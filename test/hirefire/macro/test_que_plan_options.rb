# frozen_string_literal: true

require "test_helper"

class HireFire::Macro::QuePlanOptionsTest < Minitest::Test
  def test_allowlists_skip_working_for_jqs
    opts = HireFire::Macro::Que.plan_options("jqs", {
      "skip_working" => true,
      "not_allowed" => true
    })

    assert_equal({skip_working: true}, opts)
  end

  def test_jqs_keeps_boolean_false_skip_working
    opts = HireFire::Macro::Que.plan_options("jqs", {"skip_working" => false})

    assert_equal({skip_working: false}, opts)
  end

  def test_drops_a_non_boolean_skip_working
    assert_equal({}, HireFire::Macro::Que.plan_options("jqs", {"skip_working" => "true"}))
    assert_equal({}, HireFire::Macro::Que.plan_options("jqs", {"skip_working" => nil}))
    assert_equal({}, HireFire::Macro::Que.plan_options("jqs", nil))
  end

  def test_jql_never_receives_skip_working
    assert_equal({}, HireFire::Macro::Que.plan_options("jql", {"skip_working" => true}))
  end
end
