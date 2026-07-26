# frozen_string_literal: true

require "test_helper"

class HireFire::Source::HTTPTest < Minitest::Test
  def test_name
    collector = HireFire::Source::HTTP.new(:api)
    assert_equal "api", collector.name
  end

  def test_sample_buffers_request_queue_time
    collector = HireFire::Source::HTTP.new(:web)

    Timecop.freeze Time.at(100) do
      collector.sample(25)
    end

    data = HireFire.configuration.buffer.flush
    assert_equal({100 => {sum: 25.0, count: 1}}, data.dig("web", "rqt"))
  end
end
