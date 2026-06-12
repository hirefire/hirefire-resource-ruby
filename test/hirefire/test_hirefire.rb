# frozen_string_literal: true

require "test_helper"

class HireFireTest < Minitest::Test
  def test_version
    assert_match(/\A\d+\.\d+\.\d+\z/, HireFire::VERSION)
  end

  def test_configure_yields_configuration
    config = HireFire.configure { |config| config }
    assert_equal config, HireFire.configuration
  end

  def test_configure_yields_configuration_backwards_compatible
    config = HireFire::Resource.configure { |config| config }
    assert_equal config, HireFire::Resource.configuration
  end

  def test_configure_starts_dispatcher_when_token_is_set
    ENV["HIREFIRE_TOKEN"] = "test-token-value"
    HireFire::Dispatcher.any_instance.expects(:start).once

    HireFire.configure { |config| config.dyno(:web, :rqt) }
  end

  def test_configure_does_not_start_dispatcher_without_token
    HireFire::Dispatcher.any_instance.expects(:start).never

    HireFire.configure { |config| config.dyno(:web, :rqt) }
  end

  def test_reset_stops_dispatcher_and_replaces_configuration
    configuration = HireFire.configuration
    configuration.dispatcher.expects(:stop).once

    HireFire.reset

    refute_same configuration, HireFire.configuration
  end
end
