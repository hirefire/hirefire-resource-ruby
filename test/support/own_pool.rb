# frozen_string_literal: true

module OwnPool
  def primary_checkouts_while_on_its_own_pool(model)
    primary = ActiveRecord::Base.connection_pool
    model.establish_connection(ActiveRecord::Base.connection_db_config)
    refute_same primary, model.connection_pool

    checkouts = 0
    original = primary.method(:with_connection)
    primary.define_singleton_method(:with_connection) do |**options, &block|
      checkouts += 1
      original.call(**options, &block)
    end
    yield
    checkouts
  ensure
    primary.singleton_class.remove_method(:with_connection)
    model.remove_connection
  end
end
