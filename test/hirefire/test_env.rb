# frozen_string_literal: true

require "test_helper"

class HireFire::EnvTest < Minitest::Test
  NAME = "HIREFIRE_ENV_TEST_VALUE"

  def teardown
    ENV.delete(NAME)
    super
  end

  def test_a_variable_that_is_not_set_reads_as_nil
    assert_nil HireFire::Env[NAME]
  end

  def test_an_empty_or_blank_variable_reads_as_nil
    ["", " ", "\t\n"].each do |value|
      ENV[NAME] = value

      assert_nil HireFire::Env[NAME]
    end
  end

  def test_a_value_is_read_without_its_surrounding_whitespace
    ENV[NAME] = "  web \n"

    assert_equal "web", HireFire::Env[NAME]
  end
end
