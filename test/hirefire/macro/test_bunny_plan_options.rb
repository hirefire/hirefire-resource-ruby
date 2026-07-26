# frozen_string_literal: true

require "test_helper"

class HireFire::Macro::BunnyPlanOptionsTest < Minitest::Test
  def teardown
    super
    ENV.delete("HIREFIRE_BUNNY_URL")
    ENV.delete("HIREFIRE_AMQP_URL")
  end

  def test_plan_connection_options_empty_without_env
    assert_equal({}, HireFire::Macro::Bunny.plan_connection_options)
  end

  def test_plan_connection_options_prefer_hirefire_bunny_url
    ENV["HIREFIRE_AMQP_URL"] = "amqp://amqp.example/vhost"
    ENV["HIREFIRE_BUNNY_URL"] = "amqp://bunny.example/vhost"

    assert_equal(
      {amqp_url: "amqp://bunny.example/vhost"},
      HireFire::Macro::Bunny.plan_connection_options
    )
  end

  def test_plan_connection_options_falls_back_to_hirefire_amqp_url
    ENV["HIREFIRE_AMQP_URL"] = "amqp://amqp.example/vhost"

    assert_equal(
      {amqp_url: "amqp://amqp.example/vhost"},
      HireFire::Macro::Bunny.plan_connection_options
    )
  end

  def test_plan_options_default_empty
    assert_equal({}, HireFire::Macro::Bunny.plan_options("jqs", {"x" => 1}))
  end

  def test_plan_connection_options_ignore_blank_hirefire_urls
    ENV["HIREFIRE_BUNNY_URL"] = ""
    ENV["HIREFIRE_AMQP_URL"] = "   "
    assert_equal({}, HireFire::Macro::Bunny.plan_connection_options)
  end
end
