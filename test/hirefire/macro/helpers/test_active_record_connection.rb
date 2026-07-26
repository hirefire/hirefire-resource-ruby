# frozen_string_literal: true

require "test_helper"

class HireFire::Macro::Helpers::ActiveRecordConnectionTest < Minitest::Test
  def setup
    super
    @host = Module.new do
      extend HireFire::Macro::Helpers::ActiveRecordConnection
      extend self

      def probe
        with_connection { :ran }
      end
    end
  end

  def test_yields_without_active_record
    assert_equal :ran, @host.probe
  end

  def test_uses_connection_pool_when_active_record_is_present
    pool = Object.new
    checked_out = false
    pool.define_singleton_method(:with_connection) do |&block|
      checked_out = true
      block.call
    end

    ar_base = Module.new
    ar_base.define_singleton_method(:connection_pool) { pool }

    Object.const_set(:ActiveRecord, Module.new)
    ActiveRecord.const_set(:Base, ar_base)

    assert_equal :ran, @host.probe
    assert checked_out
  ensure
    Object.send(:remove_const, :ActiveRecord) if defined?(::ActiveRecord)
  end

  def test_yields_when_active_record_lacks_connection_pool
    ar_base = Module.new
    Object.const_set(:ActiveRecord, Module.new)
    ActiveRecord.const_set(:Base, ar_base)

    assert_equal :ran, @host.probe
  ensure
    Object.send(:remove_const, :ActiveRecord) if defined?(::ActiveRecord)
  end
end
