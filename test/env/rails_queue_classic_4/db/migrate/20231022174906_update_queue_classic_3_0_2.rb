# frozen_string_literal: true

class UpdateQueueClassic302 < ActiveRecord::Migration[8.0]
  def self.up
    QC::Setup.update_to_3_0_0
  end

  def self.down
    # This migration fixes a bug, so the down step intentionally does nothing.
    # Making it irreversible was avoided too, as that could prevent rolling
    # back other, unrelated, migrations.
  end
end
