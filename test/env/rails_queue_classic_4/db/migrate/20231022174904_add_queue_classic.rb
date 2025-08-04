# frozen_string_literal: true

class AddQueueClassic < ActiveRecord::Migration[8.0]
  def self.up
    QC::Setup.create
  end

  def self.down
    QC::Setup.drop
  end
end
