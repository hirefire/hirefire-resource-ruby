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

  def test_uses_the_pool_of_the_given_model_and_not_the_primary_pool
    primary = Object.new
    primary.define_singleton_method(:with_connection) { |&_block| raise "the primary pool was checked out" }
    ar_base = Module.new
    ar_base.define_singleton_method(:connection_pool) { primary }
    Object.const_set(:ActiveRecord, Module.new)
    ActiveRecord.const_set(:Base, ar_base)

    pool = Object.new
    pool.define_singleton_method(:with_connection) { |&block| block.call(:queue_connection) }
    model = Object.new
    model.define_singleton_method(:connection_pool) { pool }
    host = @host
    host.define_singleton_method(:probe_model) { |target| with_connection(target) { |connection| connection } }

    assert_equal :queue_connection, host.probe_model(model)
  ensure
    Object.send(:remove_const, :ActiveRecord) if defined?(::ActiveRecord)
  end

  def test_yields_nil_for_a_model_without_a_connection_pool
    host = @host
    host.define_singleton_method(:probe_model) { |target| with_connection(target) { |connection| [:ran, connection] } }

    assert_equal [:ran, nil], host.probe_model(Object.new)
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
