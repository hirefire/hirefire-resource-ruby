# frozen_string_literal: true

class CreateQueSchema < ActiveRecord::Migration[6.0]
  def up
    Que.migrate!(version: 7)
  end

  def down
    Que.migrate!(version: 0)
  end
end
