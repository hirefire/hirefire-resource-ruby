# frozen_string_literal: true

class CreateQueSchema < ActiveRecord::Migration[4.2]
  def up
    Que.migrate!(version: 3)
  end

  def down
    Que.migrate!(version: 0)
  end
end
