# frozen_string_literal: true

require "test_helper"

class HireFire::WebTest < Minitest::Test
  def test_name
    web = HireFire::Web.new(name: :api)
    assert_equal "api", web.name
  end

  def test_sample_buffers_request_queue_time
    web = HireFire::Web.new(name: :web)

    Timecop.freeze Time.at(100) do
      web.sample(25)
    end

    data = HireFire.configuration.buffer.flush
    assert_equal({100 => [25]}, data[:web])
  end
end
