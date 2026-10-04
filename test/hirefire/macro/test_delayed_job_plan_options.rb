# frozen_string_literal: true

require "test_helper"

class HireFire::Macro::DelayedJobPlanOptionsTest < Minitest::Test
  def test_allowlists_skip_working_for_jqs
    opts = HireFire::Macro::Delayed::Job.plan_options("jqs", {
      "skip_working" => true,
      "not_allowed" => true
    })

    assert_equal({skip_working: true}, opts)
  end

  def test_jqs_keeps_boolean_false_skip_working
    opts = HireFire::Macro::Delayed::Job.plan_options("jqs", {"skip_working" => false})

    assert_equal({skip_working: false}, opts)
  end

  def test_drops_a_non_boolean_skip_working
    assert_equal({}, HireFire::Macro::Delayed::Job.plan_options("jqs", {"skip_working" => "true"}))
    assert_equal({}, HireFire::Macro::Delayed::Job.plan_options("jqs", {"skip_working" => nil}))
    assert_equal({}, HireFire::Macro::Delayed::Job.plan_options("jqs", nil))
  end

  def test_lease_plan_never_carries_the_priority_bounds
    opts = HireFire::Macro::Delayed::Job.plan_options("jqs", {
      "skip_working" => true,
      "min_priority" => 1,
      "max_priority" => 5
    })

    assert_equal({skip_working: true}, opts)
    assert_equal({}, HireFire::Macro::Delayed::Job.plan_options("jql", {"min_priority" => 1, "max_priority" => 5}))
  end

  def test_jql_never_receives_skip_working
    assert_equal({}, HireFire::Macro::Delayed::Job.plan_options("jql", {"skip_working" => true}))
  end
end
