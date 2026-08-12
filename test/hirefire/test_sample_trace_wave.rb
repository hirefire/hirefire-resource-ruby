# frozen_string_literal: true

require "test_helper"

class HireFire::SampleTraceWaveTest < Minitest::Test
  def test_start_returns_a_wave
    wave = HireFire::SampleTraceWave.start
    assert_instance_of HireFire::SampleTraceWave, wave
  end

  def test_finish_empty_ops
    wave = HireFire::SampleTraceWave.start
    payload = wave.finish

    assert_kind_of Numeric, payload["wave_ms"]
    assert_operator payload["wave_ms"], :>=, 0
    assert_equal [], payload["ops"]
  end

  def test_record_builds_op_shape
    wave = HireFire::SampleTraceWave.start
    entry = {
      "adapter" => "sidekiq",
      "strategy" => "jql",
      "queues" => ["default", "mailers"],
      "options" => {"schema" => "public"}
    }
    wave.record(entry, 12.3456)
    payload = wave.finish

    assert_equal 1, payload["ops"].size
    op = payload["ops"].first
    assert_equal "sidekiq", op["adapter"]
    assert_equal "jql", op["strategy"]
    assert_equal ["default", "mailers"], op["queues"]
    assert_equal({"schema" => "public"}, op["options"])
    assert_equal 12.346, op["ms"]
  end

  def test_record_normalizes_missing_and_wrong_type_fields
    wave = HireFire::SampleTraceWave.start
    wave.record(
      {"adapter" => nil, "strategy" => :jqs, "queues" => "default", "options" => ["x"]},
      1.0
    )
    op = wave.finish["ops"].first

    assert_nil op["adapter"]
    assert_equal "jqs", op["strategy"]
    assert_equal [], op["queues"]
    assert_equal({}, op["options"])
    assert_equal 1.0, op["ms"]
  end

  def test_record_nil_strategy_is_empty_string
    wave = HireFire::SampleTraceWave.start
    wave.record({"adapter" => "a", "strategy" => nil}, 0.5)
    assert_equal "", wave.finish["ops"].first["strategy"]
  end

  def test_record_non_hash_entry_coerces
    wave = HireFire::SampleTraceWave.start
    wave.record(nil, 2.0)
    wave.record("bad", 3.0)
    ops = wave.finish["ops"]

    assert_equal 2, ops.size
    ops.each do |op|
      assert_nil op["adapter"]
      assert_equal "", op["strategy"]
      assert_equal [], op["queues"]
      assert_equal({}, op["options"])
    end
    assert_equal 2.0, ops[0]["ms"]
    assert_equal 3.0, ops[1]["ms"]
  end

  def test_measure_times_block_and_records
    wave = HireFire::SampleTraceWave.start
    called = false
    result = wave.measure({"adapter" => "a", "strategy" => "jql", "queues" => ["q"]}) do
      called = true
      sleep 0.01
      :ok
    end

    assert called
    assert_equal :ok, result
    op = wave.finish["ops"].first
    assert_equal "a", op["adapter"]
    assert_equal "jql", op["strategy"]
    assert_equal ["q"], op["queues"]
    assert_kind_of Numeric, op["ms"]
    assert_operator op["ms"], :>=, 5
  end

  def test_measure_does_not_record_when_block_raises
    wave = HireFire::SampleTraceWave.start
    assert_raises(RuntimeError) do
      wave.measure({"strategy" => "jql"}) { raise "boom" }
    end
    assert_equal [], wave.finish["ops"]
  end

  def test_measure_keeps_prior_ops_when_later_raises
    wave = HireFire::SampleTraceWave.start
    wave.measure({"strategy" => "jql"}) { :ok }
    assert_raises(RuntimeError) do
      wave.measure({"strategy" => "jqs"}) { raise "boom" }
    end
    payload = wave.finish

    assert_equal 1, payload["ops"].size
    assert_equal "jql", payload["ops"].first["strategy"]
    assert_kind_of Numeric, payload["wave_ms"]
  end

  def test_finish_wave_ms_covers_all_ops
    wave = HireFire::SampleTraceWave.start
    wave.measure({"strategy" => "jql"}) { sleep 0.01 }
    wave.measure({"strategy" => "jqs"}) { sleep 0.01 }
    payload = wave.finish
    ops_ms = payload["ops"].sum { |op| op["ms"] }

    assert_equal 2, payload["ops"].size
    payload["ops"].each do |op|
      assert_operator payload["wave_ms"], :>=, op["ms"]
    end
    # Sequential ops plus gaps; 1ms slack for clock resolution.
    assert_operator payload["wave_ms"] + 1.0, :>=, ops_ms
    assert_operator payload["wave_ms"], :>=, 10
  end

  def test_finish_is_stable_when_called_twice
    wave = HireFire::SampleTraceWave.start
    wave.record({"strategy" => "jql"}, 3.0)
    first = wave.finish
    second = wave.finish

    assert_same first, second
    assert_equal first["wave_ms"], second["wave_ms"]
  end

  def test_finish_ops_isolated_from_later_record
    wave = HireFire::SampleTraceWave.start
    wave.record({"strategy" => "jql"}, 1.0)
    first = wave.finish
    first_wave_ms = first["wave_ms"]
    first_ops = first["ops"]

    sleep 0.01
    wave.record({"strategy" => "jqs"}, 2.0)
    second = wave.finish

    assert_equal 1, first_ops.size
    assert_equal "jql", first_ops.first["strategy"]
    assert_equal first_wave_ms, first["wave_ms"]
    assert_equal 2, second["ops"].size
    refute_same first, second
    assert_operator second["wave_ms"], :>=, first_wave_ms
  end

  def test_log_writes_wave_and_per_op_lines
    logger = Logger.new(io = StringIO.new)
    wave = HireFire::SampleTraceWave.start
    wave.record(
      {"adapter" => "sidekiq", "strategy" => "jql", "queues" => ["default"]},
      4.5
    )
    wave.log_to(logger)

    assert_includes io.string, "sample_job_queues wave_ms="
    assert_includes io.string, "ops=1"
    assert_includes io.string, 'sample adapter="sidekiq" strategy=jql'
    assert_includes io.string, "queues=default"
    assert_includes io.string, "ms=4.5"
  end
end
