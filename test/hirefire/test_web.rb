# frozen_string_literal: true

require "test_helper"

class HireFire::WebTest < Minitest::Test
  def test_name
    web = HireFire::Web.new(name: :api)
    assert_equal "api", web.name
  end
end
