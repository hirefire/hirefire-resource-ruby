# frozen_string_literal: true

class CreateQueSchema < ActiveRecord::Migration[5.0]
  def up
    Que.migrate!(version: 5)
  end

  def down
    Que.migrate!(version: 0)
  end
end
