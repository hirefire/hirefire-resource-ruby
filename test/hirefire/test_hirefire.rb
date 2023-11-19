# frozen_string_literal: true

require "test_helper"

class HireFireTest < Minitest::Test
  def test_configure_yields_configuration
    config = HireFire.configure { |config| config }
    assert_equal config, HireFire.configuration
  end

  def test_configure_yields_configuration_backwards_compatible
    config = HireFire::Resource.configure { |config| config }
    assert_equal config, HireFire::Resource.configuration
  end
end
