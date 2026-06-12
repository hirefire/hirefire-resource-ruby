# frozen_string_literal: true

require "test_helper"

class HireFire::UtilityTest < Minitest::Test
  include HireFire::Utility

  def test_normalizes_symbols_and_strings_to_a_string_set
    assert_equal Set.new(%w[default mailer]),
      normalize_queues([:default, "mailer"], allow_empty: false)
  end

  def test_flattens_nested_queue_lists
    assert_equal Set.new(%w[default mailer]),
      normalize_queues([[:default, [:mailer]]], allow_empty: false)
  end

  def test_strips_surrounding_whitespace
    assert_equal Set.new(%w[default]),
      normalize_queues([" default "], allow_empty: false)
  end

  def test_deduplicates_queue_names
    assert_equal Set.new(%w[default]),
      normalize_queues([:default, "default"], allow_empty: false)
  end

  def test_empty_queues_allowed
    assert_equal Set.new, normalize_queues([], allow_empty: true)
  end

  def test_empty_queues_disallowed_raises
    assert_raises HireFire::Errors::MissingQueueError do
      normalize_queues([], allow_empty: false)
    end
  end
end
