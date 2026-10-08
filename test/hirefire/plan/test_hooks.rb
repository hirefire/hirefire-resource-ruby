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
    super
    @helper = Object.new.extend(HireFire::Plan::Hooks)
    @host = Object.new.extend(HireFire::Plan::Hooks)
    @host.define_singleton_method(:plan_options) { |strategy, options| extract_plan_options(strategy, options, SCHEMA) }
  end

  def test_plan_options_keep_the_listed_keys_and_coerce_their_values
    opts = @host.plan_options("jqs", {
      "skip_working" => true,
      "server" => false,
      "max_scheduled" => "50",
      "not_allowed" => true,
      :skip_working => true
    })

    assert_equal({skip_working: true, server: false, max_scheduled: 50}, opts)
  end

  def test_plan_options_drop_values_of_the_wrong_type_and_input_that_is_not_a_hash
    assert_equal({}, @host.plan_options("jqs", nil))
    assert_equal({}, @host.plan_options("jqs", "nope"))
    assert_equal({}, @host.plan_options("unknown", {"server" => true}))
    assert_equal({server: true}, @host.plan_options("jqs", {"skip_working" => "true", "max_scheduled" => -1, "server" => true}))
  end

  def test_a_boolean_option_takes_true_and_false_only
    assert_equal({skip_working: true}, @host.plan_options("jqs", {"skip_working" => true}))
    assert_equal({skip_working: false}, @host.plan_options("jqs", {"skip_working" => false}))
    assert_equal({}, @host.plan_options("jqs", {"skip_working" => "true"}))
    assert_equal({}, @host.plan_options("jqs", {"skip_working" => 1}))
    assert_equal({}, @host.plan_options("jqs", {"skip_working" => nil}))
  end

  def test_a_count_option_takes_whole_numbers_from_zero_as_integers_or_digit_strings
    assert_equal({max_scheduled: 0}, @host.plan_options("jqs", {"max_scheduled" => 0}))
    assert_equal({max_scheduled: 10}, @host.plan_options("jqs", {"max_scheduled" => "10"}))
    assert_equal({max_scheduled: 7}, @host.plan_options("jqs", {"max_scheduled" => "+7"}))
    [-1, "-1", "x", "1x", 50.9, 10.0, "", nil, [1]].each do |value|
      assert_equal({}, @host.plan_options("jqs", {"max_scheduled" => value}), "#{value.inspect} was accepted")
    end
  end

  def test_the_option_helpers_are_not_part_of_the_public_surface_of_a_macro
    refute_respond_to @helper, :extract_plan_options
    refute_respond_to @helper, :coerce_plan_value
    refute_respond_to HireFire::Macro::Sidekiq, :extract_plan_options
    refute_respond_to HireFire::Macro::Bunny, :coerce_plan_value
  end

  def test_a_macro_reports_its_library_as_not_loaded_by_default
    refute @helper.library_loaded?
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

  def test_default_queues_required_is_false
    refute @helper.queues_required?
  end
end
