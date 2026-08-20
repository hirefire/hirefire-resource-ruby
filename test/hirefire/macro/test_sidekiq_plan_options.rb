# frozen_string_literal: true

require "test_helper"

class HireFire::Macro::SidekiqPlanOptionsTest < Minitest::Test
  def test_allowlists_jqs_options
    opts = HireFire::Macro::Sidekiq.plan_options("jqs", {
      "skip_working" => true,
      "skip_retries" => true,
      "skip_scheduled" => true,
      "max_scheduled" => 50,
      "server" => true,
      "not_allowed" => true
    })

    assert_equal({
      skip_working: true,
      skip_retries: true,
      skip_scheduled: true,
      max_scheduled: 50,
      server: true
    }, opts)
  end

  def test_coerces_option_values_strictly
    opts = HireFire::Macro::Sidekiq.plan_options("jqs", {
      "skip_working" => "false",
      "server" => false,
      "max_scheduled" => "100"
    })

    assert_equal({server: false, max_scheduled: 100}, opts)
  end

  def test_jqs_keeps_boolean_false_skip_working
    opts = HireFire::Macro::Sidekiq.plan_options("jqs", {
      "skip_working" => false,
      "server" => true
    })

    assert_equal({skip_working: false, server: true}, opts)
  end

  def test_jql_only_allows_latency_options
    opts = HireFire::Macro::Sidekiq.plan_options("jql", {
      "skip_retries" => true,
      "skip_scheduled" => true,
      "skip_working" => true,
      "server" => true,
      "max_scheduled" => 10
    })

    assert_equal({skip_retries: true, skip_scheduled: true}, opts)
  end
end
