# frozen_string_literal: true

require "test_helper"

class HireFire::Dispatcher::PayloadTest < Minitest::Test
  Payload = HireFire::Dispatcher::Payload

  def build(data, liveness: nil, since: nil, trace: nil, &omitted)
    omitted ||= ->(name, strategy) { flunk "#{strategy} of #{name} was left out" }
    Payload.build(data, liveness: liveness, since: since, trace: trace, &omitted)
  end

  def rqt(sum, count)
    {sum: sum, count: count}
  end

  def test_an_empty_buffer_without_liveness_gives_no_entry_and_no_watermark
    assert_equal [[], nil], build({})
  end

  def test_job_and_cpu_values_are_sent_as_bare_numbers_under_their_second
    data = {"worker" => {"jqs" => {1000 => 12, 1001 => 0}, "wrk" => {1000 => 3}}, "clock" => {"cpu" => {1000 => 12.5}}}

    entries, watermark = build(data)

    assert_equal [
      {"name" => "worker", "metrics" => {"jqs" => {"1000" => 12, "1001" => 0}, "wrk" => {"1000" => 3}}},
      {"name" => "clock", "metrics" => {"cpu" => {"1000" => 12.5}}}
    ], entries
    assert_nil watermark
  end

  def test_request_queue_time_is_sent_as_its_mean_and_its_count
    entries, = build({"web" => {"rqt" => {1000 => rqt(30.0, 4), 1001 => rqt(0.0, 0)}}})

    assert_equal [{"name" => "web", "metrics" => {"rqt" => {"1000" => [7.5, 4], "1001" => []}}}], entries
  end

  def test_liveness_claims_only_the_current_second_on_the_first_build
    Timecop.freeze(Time.at(1000)) do
      entries, watermark = build({}, liveness: "web")

      assert_equal [{"name" => "web", "metrics" => {"rqt" => {"1000" => []}}}], entries
      assert_equal 1000, watermark
    end
  end

  def test_liveness_claims_every_second_after_the_last_one_sent_and_keeps_the_samples
    Timecop.freeze(Time.at(1003)) do
      entries, watermark = build({"web" => {"rqt" => {1002 => rqt(5.0, 1)}}}, liveness: "web", since: 1000)

      assert_equal({"1001" => [], "1002" => [5.0, 1], "1003" => []}, entries.first.dig("metrics", "rqt"))
      assert_equal 1003, watermark
    end
  end

  def test_liveness_reaches_back_no_further_than_the_backfill_limit
    limit = HireFire::Dispatcher::RQT_BACKFILL_LIMIT
    assert_equal 60, limit

    Timecop.freeze(Time.at(2000)) do
      entries, watermark = build({}, liveness: "web", since: 1000)
      seconds = entries.first.dig("metrics", "rqt").keys.map(&:to_i)

      assert_equal (2000 - limit..2000).to_a, seconds
      assert_equal 2000, watermark
    end
  end

  def test_a_last_second_in_the_future_claims_the_current_second
    Timecop.freeze(Time.at(1000)) do
      entries, watermark = build({}, liveness: "web", since: 1500)

      assert_equal ["1000"], entries.first.dig("metrics", "rqt").keys
      assert_equal 1000, watermark
    end
  end

  def test_the_entry_with_liveness_comes_first_and_carries_its_other_series
    Timecop.freeze(Time.at(1000)) do
      data = {"worker" => {"jqs" => {1000 => 2}}, "web" => {"rqt" => {1000 => rqt(8.0, 2)}, "cpu" => {1000 => 40.0}}}

      entries, = build(data, liveness: "web")

      assert_equal %w[web worker], entries.map { |entry| entry["name"] }
      assert_equal({"rqt" => {"1000" => [4.0, 2]}, "cpu" => {"1000" => 40.0}}, entries.first["metrics"])
    end
  end

  def test_without_liveness_buffered_request_queue_time_is_sent_as_it_is
    Timecop.freeze(Time.at(1005)) do
      entries, watermark = build({"web" => {"rqt" => {1000 => rqt(8.0, 2)}}})

      assert_equal({"1000" => [4.0, 2]}, entries.first.dig("metrics", "rqt"))
      assert_nil watermark
    end
  end

  def test_the_buffered_buckets_are_not_changed
    data = {"web" => {"rqt" => {1002 => rqt(5.0, 1)}}}

    Timecop.freeze(Time.at(1003)) { build(data, liveness: "web", since: 1000) }

    assert_equal({"web" => {"rqt" => {1002 => {sum: 5.0, count: 1}}}}, data)
  end

  def test_a_value_at_the_limit_is_sent_and_a_value_over_it_or_under_zero_is_left_out_and_reported
    limit = HireFire::Dispatcher::METRIC_VALUE_LIMIT
    assert_equal 1e15, limit
    omitted = []
    data = {
      "worker" => {"jqs" => {1000 => limit, 1001 => limit + 1e3, 1002 => -1, 1003 => 0}},
      "web" => {"rqt" => {1000 => rqt(limit * 2, 1), 1001 => rqt(limit, 1), 1002 => rqt(-5.0, 1)}}
    }

    entries, = build(data) { |name, strategy| omitted << [name, strategy] }

    assert_equal({"1000" => limit, "1003" => 0}, entries.first.dig("metrics", "jqs"))
    assert_equal({"1001" => [limit, 1]}, entries.last.dig("metrics", "rqt"))
    assert_equal [%w[worker jqs], %w[worker jqs], %w[web rqt], %w[web rqt]], omitted
  end

  def test_a_series_or_an_entry_with_nothing_left_to_send_is_dropped
    data = {"worker" => {"jqs" => {1000 => -1}, "jql" => {}}, "mailer" => {"jqs" => {1000 => 4}}}

    entries, = build(data) { |_name, _strategy| }

    assert_equal [{"name" => "mailer", "metrics" => {"jqs" => {"1000" => 4}}}], entries
  end

  def test_the_trace_goes_on_the_first_entry_and_nowhere_when_there_is_none
    trace = {"wave_ms" => 1.5, "ops" => []}

    entries, = build({"worker" => {"jqs" => {1000 => 1}}, "mailer" => {"jqs" => {1000 => 2}}}, trace: trace)

    assert_equal trace, entries.first["sample_trace"]
    refute entries.last.key?("sample_trace")
    assert_equal [[], nil], build({}, trace: trace)
  end

  def test_traced_tells_whether_the_first_entry_carries_a_trace
    plain, = build({"worker" => {"jqs" => {1000 => 1}}})
    traced, = build({"worker" => {"jqs" => {1000 => 1}}}, trace: {"ops" => []})

    refute Payload.traced?(plain)
    assert Payload.traced?(traced)
  end

  def test_without_trace_returns_the_same_entries_less_the_trace_and_leaves_the_original
    traced, = build({"worker" => {"jqs" => {1000 => 1}}, "mailer" => {"jqs" => {1000 => 2}}}, trace: {"ops" => []})

    stripped = Payload.without_trace(traced)

    assert_equal [{"name" => "worker", "metrics" => {"jqs" => {"1000" => 1}}}, {"name" => "mailer", "metrics" => {"jqs" => {"1000" => 2}}}], stripped
    assert Payload.traced?(traced)
  end
end
