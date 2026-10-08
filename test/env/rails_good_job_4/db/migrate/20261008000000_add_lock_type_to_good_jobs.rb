# frozen_string_literal: true

class AddLockTypeToGoodJobs < ActiveRecord::Migration[8.0]
  def change
    add_column :good_jobs, :lock_type, :integer, limit: 2
  end
end
