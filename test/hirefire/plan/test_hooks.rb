# frozen_string_literal: true

require "test_helper"

class HireFire::Plan::HooksTest < Minitest::Test
  SCHEMA = {
    "jql" => {
      "skip_retries" => :boolean,
      "skip_scheduled" => :boolean
    }.freeze,
    "jqs" => {
      "skip_working" => :boolean,
      "max_scheduled" => :non_negative_integer,
      "server" => :boolean
    }.freeze
  }.freeze

  def setup
    @helper = Object.new.extend(HireFire::Plan::Hooks)
  end

  def test_extract_allowlists_and_coerces
    opts = @helper.extract_plan_options("jqs", {
      "skip_working" => true,
      "server" => false,
      "max_scheduled" => "50",
      "not_allowed" => true,
      skip_working: true
    }, SCHEMA)

    assert_equal({skip_working: true, server: false, max_scheduled: 50}, opts)
  end

  def test_extract_drops_invalid_and_non_hash
    assert_equal({}, @helper.extract_plan_options("jqs", nil, SCHEMA))
    assert_equal({}, @helper.extract_plan_options("jqs", "nope", SCHEMA))
    assert_equal({}, @helper.extract_plan_options("unknown", {"server" => true}, SCHEMA))

    opts = @helper.extract_plan_options("jqs", {
      "skip_working" => "true",
      "max_scheduled" => -1,
      "server" => true
    }, SCHEMA)

    assert_equal({server: true}, opts)
  end

  def test_coerce_plan_value
    assert_equal true, @helper.coerce_plan_value(:boolean, true)
    assert_equal false, @helper.coerce_plan_value(:boolean, false)
    assert_nil @helper.coerce_plan_value(:boolean, "true")
    assert_equal 0, @helper.coerce_plan_value(:non_negative_integer, 0)
    assert_equal 10, @helper.coerce_plan_value(:non_negative_integer, "10")
    assert_nil @helper.coerce_plan_value(:non_negative_integer, -1)
    assert_nil @helper.coerce_plan_value(:non_negative_integer, "x")
    assert_nil @helper.coerce_plan_value(:unknown, 1)
  end

  def test_default_plan_hooks_empty
    assert_equal({}, @helper.plan_options("jql", {"a" => 1}))
    assert_equal({}, @helper.plan_connection_options)
  end

  def test_default_supports_plan_strategy
    assert @helper.supports_plan_strategy?("jql")
    assert @helper.supports_plan_strategy?("jqs")
    assert @helper.supports_plan_strategy?(:jql)
    refute @helper.supports_plan_strategy?("rpm")
    refute @helper.supports_plan_strategy?("unknown")
  end
end
