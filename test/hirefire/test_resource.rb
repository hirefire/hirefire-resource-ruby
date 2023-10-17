# frozen_string_literal: true

require "test_helper"

class HireFire::ResourceTest < Minitest::Test
  def test_version_presence
    refute_nil HireFire::Resource::VERSION
  end

  def test_configure_yields_configuration
    config = HireFire::Resource.configure { |config| config }
    assert_equal config, HireFire::Resource.configuration
  end
end
