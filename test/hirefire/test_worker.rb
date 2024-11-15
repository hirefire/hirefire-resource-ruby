# frozen_string_literal: true

require "test_helper"

class HireFire::WorkerTest < Minitest::Test
  def test_setup_and_methods
    valid_names = [
      "worker",
      "worker1",
      "my-worker",
      "my_worker",
      "Worker_123",
      "worker-123",
      "w",
      "a" * 63
    ]

    valid_names.each do |name|
      worker = HireFire::Worker.new(name) { 1 + 1 }
      assert_equal name, worker.name
      assert_equal 2, worker.value
    end
  end

  def test_invalid_dyno_name_error
    invalid_names = [
      "", # Empty string
      "1worker", # Starts with a digit
      "-worker", # Starts with a dash
      "_worker", # Starts with an underscore
      "worker!", # Contains an invalid character
      " worker", # Starts with a space
      "worker ", # Ends with a space
      "a" * 64 # Exceeds maximum length
    ]

    invalid_names.each do |name|
      assert_raises(HireFire::Worker::InvalidDynoNameError) do
        HireFire::Worker.new(name) { 1 + 1 }
      end
    end
  end

  def test_missing_dyno_block_error
    assert_raises(HireFire::Worker::MissingDynoBlockError) do
      HireFire::Worker.new(:worker)
    end
  end
end
