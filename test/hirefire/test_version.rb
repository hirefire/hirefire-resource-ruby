# frozen_string_literal: true

require "test_helper"

class HireFire::Test < Minitest::Test
  def test_version
    assert_match(/\A\d+\.\d+\.\d+\z/, HireFire::VERSION)
  end
end
