# frozen_string_literal: true

require "test_helper"

class HireFireTest < Minitest::Test
  def test_configure_yields_configuration
    config = HireFire.configure { |config| config }
    assert_equal config, HireFire.configuration
  end
end
