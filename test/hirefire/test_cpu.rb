# frozen_string_literal: true

require "test_helper"
require "tempfile"

class HireFire::Source::CPUTest < Minitest::Test
  def buffer
    HireFire.configuration.buffer
  end

  def test_first_sample_only_seeds_the_baseline
    HireFire::Source::CPU::Usage.stubs(:reading).returns([10.0, :cgroup_v2])
    HireFire::Source::CPU::Usage.stubs(:available_cpus).returns(1.0)

    collector = HireFire::Source::CPU.new("clock")
    Timecop.freeze(Time.at(1000)) { assert_nil collector.sample }
    assert_empty buffer.flush
  end

  def test_second_sample_buffers_normalized_percentage
    HireFire::Source::CPU::Usage.stubs(:reading).returns([10.0, :cgroup_v2], [10.5, :cgroup_v2])
    HireFire::Source::CPU::Usage.stubs(:available_cpus).returns(1.0)

    collector = HireFire::Source::CPU.new("clock")
    Timecop.freeze(Time.at(1000)) { collector.sample }
    Timecop.freeze(Time.at(1001)) { collector.sample }

    assert_equal({1001 => 50.0}, buffer.flush.dig("clock", "cpu"))
  end

  def test_normalizes_by_available_cpus
    HireFire::Source::CPU::Usage.stubs(:reading).returns([0.0, :cgroup_v2], [1.0, :cgroup_v2])
    HireFire::Source::CPU::Usage.stubs(:available_cpus).returns(4.0)

    collector = HireFire::Source::CPU.new("worker")
    Timecop.freeze(Time.at(1000)) { collector.sample }
    Timecop.freeze(Time.at(1001)) { collector.sample }

    assert_equal({1001 => 25.0}, buffer.flush.dig("worker", "cpu"))
  end

  def test_normalizes_by_fractional_available_cpus
    HireFire::Source::CPU::Usage.stubs(:reading).returns([0.0, :cgroup_v2], [0.25, :cgroup_v2])
    HireFire::Source::CPU::Usage.stubs(:available_cpus).returns(0.5)

    collector = HireFire::Source::CPU.new("clock")
    Timecop.freeze(Time.at(1000)) { collector.sample }
    Timecop.freeze(Time.at(1001)) { collector.sample }

    assert_equal({1001 => 50.0}, buffer.flush.dig("clock", "cpu"))
  end

  def test_sample_rounds_percentage_to_two_decimal_places
    HireFire::Source::CPU::Usage.stubs(:reading).returns([0.0, :cgroup_v2], [1.0 / 3.0, :cgroup_v2])
    HireFire::Source::CPU::Usage.stubs(:available_cpus).returns(1.0)

    collector = HireFire::Source::CPU.new("clock")
    Timecop.freeze(Time.at(1000)) { collector.sample }
    Timecop.freeze(Time.at(1001)) { collector.sample }

    assert_equal({1001 => 33.33}, buffer.flush.dig("clock", "cpu"))
  end

  def test_clamps_to_100_percent
    HireFire::Source::CPU::Usage.stubs(:reading).returns([0.0, :cgroup_v2], [5.0, :cgroup_v2])
    HireFire::Source::CPU::Usage.stubs(:available_cpus).returns(1.0)

    collector = HireFire::Source::CPU.new("clock")
    Timecop.freeze(Time.at(1000)) { collector.sample }
    Timecop.freeze(Time.at(1001)) { collector.sample }

    assert_equal({1001 => 100.0}, buffer.flush.dig("clock", "cpu"))
  end

  def test_zero_utilization_buffers_zero
    HireFire::Source::CPU::Usage.stubs(:reading).returns([10.0, :cgroup_v2], [10.0, :cgroup_v2])
    HireFire::Source::CPU::Usage.stubs(:available_cpus).returns(1.0)

    collector = HireFire::Source::CPU.new("clock")
    Timecop.freeze(Time.at(1000)) { collector.sample }
    Timecop.freeze(Time.at(1001)) { collector.sample }

    assert_equal({1001 => 0.0}, buffer.flush.dig("clock", "cpu"))
  end

  def test_negative_usage_delta_skips_and_reseeds_the_baseline
    HireFire::Source::CPU::Usage.stubs(:reading).returns([10.0, :cgroup_v2], [5.0, :cgroup_v2], [5.5, :cgroup_v2])
    HireFire::Source::CPU::Usage.stubs(:available_cpus).returns(1.0)

    collector = HireFire::Source::CPU.new("clock")
    Timecop.freeze(Time.at(1000)) { collector.sample }
    Timecop.freeze(Time.at(1001)) { assert_nil collector.sample }
    Timecop.freeze(Time.at(1002)) { collector.sample }

    assert_equal({1002 => 50.0}, buffer.flush.dig("clock", "cpu"))
  end

  def test_source_change_skips_and_reseeds_the_baseline
    HireFire::Source::CPU::Usage.stubs(:reading).returns([10.0, :process], [11.0, :cgroup_v2], [11.5, :cgroup_v2])
    HireFire::Source::CPU::Usage.stubs(:available_cpus).returns(1.0)

    collector = HireFire::Source::CPU.new("clock")
    Timecop.freeze(Time.at(1000)) { collector.sample }
    Timecop.freeze(Time.at(1001)) { assert_nil collector.sample }
    Timecop.freeze(Time.at(1002)) { collector.sample }

    assert_equal({1002 => 50.0}, buffer.flush.dig("clock", "cpu"))
  end

  def test_skips_sample_when_usage_unavailable
    HireFire::Source::CPU::Usage.stubs(:reading).returns([nil, nil])
    HireFire::Source::CPU::Usage.stubs(:available_cpus).returns(1.0)

    collector = HireFire::Source::CPU.new("clock")
    Timecop.freeze(Time.at(1000)) { collector.sample }
    Timecop.freeze(Time.at(1001)) { assert_nil collector.sample }
    assert_empty buffer.flush
  end

  def test_non_positive_elapsed_delta_skips_the_sample
    HireFire::Source::CPU::Usage.stubs(:reading).returns([10.0, :cgroup_v2], [10.5, :cgroup_v2])
    HireFire::Source::CPU::Usage.stubs(:available_cpus).returns(1.0)

    collector = HireFire::Source::CPU.new("clock")
    Timecop.freeze(Time.at(1000)) do
      collector.sample
      assert_nil collector.sample
    end
    assert_empty buffer.flush
  end

  def test_elapsed_delta_uses_the_monotonic_clock_not_wall_time
    HireFire::Source::CPU::Usage.stubs(:reading).returns([10.0, :cgroup_v2], [10.5, :cgroup_v2])
    HireFire::Source::CPU::Usage.stubs(:available_cpus).returns(1.0)

    collector = HireFire::Source::CPU.new("clock")
    HireFire::Clock.stubs(:monotonic).returns(100.0, 101.0)

    Timecop.freeze(Time.at(1000)) do
      collector.sample
      collector.sample
    end

    assert_equal({1000 => 50.0}, buffer.flush.dig("clock", "cpu"))
  end

  def test_skips_sample_when_available_cpus_is_nil
    HireFire::Source::CPU::Usage.stubs(:reading).returns([0.0, :cgroup_v2], [1.0, :cgroup_v2])
    HireFire::Source::CPU::Usage.stubs(:available_cpus).returns(nil)

    collector = HireFire::Source::CPU.new("clock")
    Timecop.freeze(Time.at(1000)) { collector.sample }
    Timecop.freeze(Time.at(1001)) { assert_nil collector.sample }
    assert_empty buffer.flush
  end

  def test_skips_sample_when_available_cpus_is_zero
    HireFire::Source::CPU::Usage.stubs(:reading).returns([0.0, :cgroup_v2], [1.0, :cgroup_v2])
    HireFire::Source::CPU::Usage.stubs(:available_cpus).returns(0.0)

    collector = HireFire::Source::CPU.new("clock")
    Timecop.freeze(Time.at(1000)) { collector.sample }
    Timecop.freeze(Time.at(1001)) { assert_nil collector.sample }
    assert_empty buffer.flush
  end

  def test_recovers_after_an_initially_unavailable_usage_source
    HireFire::Source::CPU::Usage.stubs(:reading).returns([nil, nil], [10.0, :cgroup_v2], [10.5, :cgroup_v2])
    HireFire::Source::CPU::Usage.stubs(:available_cpus).returns(1.0)

    collector = HireFire::Source::CPU.new("clock")
    Timecop.freeze(Time.at(1000)) { assert_nil collector.sample }
    Timecop.freeze(Time.at(1001)) { assert_nil collector.sample }
    Timecop.freeze(Time.at(1002)) { collector.sample }

    assert_equal({1002 => 50.0}, buffer.flush.dig("clock", "cpu"))
  end
end

class HireFire::Source::CPU::UsageTest < Minitest::Test
  Usage = HireFire::Source::CPU::Usage

  def test_total_seconds_prefers_cgroup_v2
    Usage.stubs(:read).with(Usage::CGROUP_V2_USAGE).returns("usage_usec 2500000\nuser_usec 1000000")
    assert_in_delta 2.5, Usage.total_seconds, 0.0001
  end

  def test_cgroup_v2_zero_usage_is_accepted_not_fallthrough
    Usage.stubs(:read).with(Usage::CGROUP_V2_USAGE).returns("usage_usec 0\nuser_usec 0")
    seconds, source = Usage.reading
    assert_in_delta 0.0, seconds, 0.0001
    assert_equal :cgroup_v2, source
  end

  def test_cgroup_v1_zero_usage_is_accepted_not_fallthrough
    Usage.stubs(:read).with(Usage::CGROUP_V2_USAGE).returns(nil)
    Usage.stubs(:read).with(Usage::CGROUP_V1_USAGE).returns("0")
    seconds, source = Usage.reading
    assert_in_delta 0.0, seconds, 0.0001
    assert_equal :cgroup_v1, source
  end

  def test_total_seconds_falls_back_to_cgroup_v1
    Usage.stubs(:read).with(Usage::CGROUP_V2_USAGE).returns(nil)
    Usage.stubs(:read).with(Usage::CGROUP_V1_USAGE).returns("3000000000")
    assert_in_delta 3.0, Usage.total_seconds, 0.0001
  end

  def test_total_seconds_falls_through_on_malformed_cgroup_v2
    Usage.stubs(:read).with(Usage::CGROUP_V2_USAGE).returns("usage_usec garbage")
    Usage.stubs(:read).with(Usage::CGROUP_V1_USAGE).returns("3000000000")
    assert_in_delta 3.0, Usage.total_seconds, 0.0001
  end

  def test_reading_labels_the_active_source
    Usage.stubs(:read).with(Usage::CGROUP_V2_USAGE).returns("usage_usec 2500000")
    seconds, source = Usage.reading
    assert_in_delta 2.5, seconds, 0.0001
    assert_equal :cgroup_v2, source
  end

  def test_reading_labels_the_source_it_falls_through_to
    Usage.stubs(:read).with(Usage::CGROUP_V2_USAGE).returns(nil)
    Usage.stubs(:read).with(Usage::CGROUP_V1_USAGE).returns("3000000000")
    seconds, source = Usage.reading
    assert_in_delta 3.0, seconds, 0.0001
    assert_equal :cgroup_v1, source
  end

  def test_reading_labels_proc_source
    Usage.stubs(:cgroup_v2_seconds).returns(nil)
    Usage.stubs(:cgroup_v1_seconds).returns(nil)
    Dir.stubs(:glob).with(Usage::PROC_STAT_GLOB).returns(["/proc/1/stat"])
    Usage.stubs(:read).with("/proc/1/stat").returns("1 (ruby) S 0 1 1 0 -1 0 0 0 0 0 500 250 0 0 20 0 1 0 9 0 0")
    Usage.stubs(:clock_ticks).returns(100)

    seconds, source = Usage.reading
    assert_in_delta 7.5, seconds, 0.0001
    assert_equal :proc, source
  end

  def test_reading_labels_process_source
    Usage.stubs(:cgroup_v2_seconds).returns(nil)
    Usage.stubs(:cgroup_v1_seconds).returns(nil)
    Usage.stubs(:proc_namespace_seconds).returns(nil)
    Usage.stubs(:process_seconds).returns(1.25)

    seconds, source = Usage.reading
    assert_in_delta 1.25, seconds, 0.0001
    assert_equal :process, source
  end

  def test_reading_returns_nil_when_every_source_fails
    Usage.stubs(:cgroup_v2_seconds).returns(nil)
    Usage.stubs(:cgroup_v1_seconds).returns(nil)
    Usage.stubs(:proc_namespace_seconds).returns(nil)
    Usage.stubs(:process_seconds).returns(nil)

    assert_equal [nil, nil], Usage.reading
    assert_nil Usage.total_seconds
  end

  def test_total_seconds_falls_back_to_proc_namespace_sum
    Usage.stubs(:read).with(Usage::CGROUP_V2_USAGE).returns(nil)
    Usage.stubs(:read).with(Usage::CGROUP_V1_USAGE).returns(nil)
    Dir.stubs(:glob).with(Usage::PROC_STAT_GLOB).returns(["/proc/1/stat", "/proc/2/stat"])
    Usage.stubs(:read).with("/proc/1/stat").returns("1 (ruby) S 0 1 1 0 -1 0 0 0 0 0 500 250 0 0 20 0 1 0 9 0 0")
    Usage.stubs(:read).with("/proc/2/stat").returns("2 (puma (worker)) S 1 1 1 0 -1 0 0 0 0 0 150 100 0 0 20 0 1 0 9 0 0")
    Usage.stubs(:clock_ticks).returns(100)

    assert_in_delta 10.0, Usage.total_seconds, 0.0001
  end

  def test_proc_namespace_seconds_nil_without_proc
    Dir.stubs(:glob).with(Usage::PROC_STAT_GLOB).returns([])
    assert_nil Usage.proc_namespace_seconds
  end

  def test_stat_ticks_parses_around_comm_with_spaces_and_parens
    line = "4242 (rails (worker)) S 1 1 1 0 -1 0 0 0 0 0 500 250 0 0 20 0 1 0 100 0 0"
    assert_equal 750, Usage.stat_ticks(line)
  end

  def test_total_seconds_falls_back_to_process_clock
    Usage.stubs(:read).returns(nil)
    Dir.stubs(:glob).with(Usage::PROC_STAT_GLOB).returns([])
    assert_kind_of Float, Usage.total_seconds
  end

  def test_available_cpus_reads_cgroup_v2_quota
    Usage.stubs(:read).with(Usage::CGROUP_V2_QUOTA).returns("50000 100000")
    assert_in_delta 0.5, Usage.available_cpus, 0.0001
  end

  def test_available_cpus_ignores_unlimited_v2_quota
    Usage.stubs(:read).with(Usage::CGROUP_V2_QUOTA).returns("max 100000")
    Usage.stubs(:read).with(Usage::CGROUP_V1_QUOTA).returns(nil)
    Usage.stubs(:read).with(Usage::CGROUP_V1_PERIOD).returns(nil)
    assert_equal Etc.nprocessors, Usage.available_cpus
  end

  def test_available_cpus_falls_through_on_malformed_quota
    Usage.stubs(:read).with(Usage::CGROUP_V2_QUOTA).returns("abc 100000")
    Usage.stubs(:read).with(Usage::CGROUP_V1_QUOTA).returns(nil)
    Usage.stubs(:read).with(Usage::CGROUP_V1_PERIOD).returns(nil)
    assert_equal Etc.nprocessors, Usage.available_cpus
  end

  def test_available_cpus_ignores_a_non_positive_v2_quota
    Usage.stubs(:read).with(Usage::CGROUP_V2_QUOTA).returns("0 100000")
    Usage.stubs(:read).with(Usage::CGROUP_V1_QUOTA).returns(nil)
    Usage.stubs(:read).with(Usage::CGROUP_V1_PERIOD).returns(nil)
    assert_equal Etc.nprocessors, Usage.available_cpus
  end

  def test_available_cpus_ignores_non_positive_v2_period
    Usage.stubs(:read).with(Usage::CGROUP_V2_QUOTA).returns("50000 0")
    Usage.stubs(:read).with(Usage::CGROUP_V1_QUOTA).returns(nil)
    Usage.stubs(:read).with(Usage::CGROUP_V1_PERIOD).returns(nil)
    assert_equal Etc.nprocessors, Usage.available_cpus
  end

  def test_available_cpus_ignores_non_positive_v1_period
    Usage.stubs(:read).with(Usage::CGROUP_V2_QUOTA).returns(nil)
    Usage.stubs(:read).with(Usage::CGROUP_V1_QUOTA).returns("150000")
    Usage.stubs(:read).with(Usage::CGROUP_V1_PERIOD).returns("0")
    assert_equal Etc.nprocessors, Usage.available_cpus
  end

  def test_available_cpus_ignores_a_non_positive_v1_quota
    Usage.stubs(:read).with(Usage::CGROUP_V2_QUOTA).returns(nil)
    Usage.stubs(:read).with(Usage::CGROUP_V1_QUOTA).returns("0")
    Usage.stubs(:read).with(Usage::CGROUP_V1_PERIOD).returns("100000")
    assert_equal Etc.nprocessors, Usage.available_cpus
  end

  def test_available_cpus_reads_cgroup_v1_quota
    Usage.stubs(:read).with(Usage::CGROUP_V2_QUOTA).returns(nil)
    Usage.stubs(:read).with(Usage::CGROUP_V1_QUOTA).returns("150000")
    Usage.stubs(:read).with(Usage::CGROUP_V1_PERIOD).returns("100000")
    assert_in_delta 1.5, Usage.available_cpus, 0.0001
  end

  def test_available_cpus_falls_back_to_processor_count
    Usage.stubs(:read).returns(nil)
    assert_equal Etc.nprocessors, Usage.available_cpus
  end

  def test_cedar_shared_1x_entitlement_from_memory_fingerprint
    ENV["DYNO"] = "worker.1"
    Usage.stubs(:read).with(Usage::CGROUP_V2_QUOTA).returns(nil)
    Usage.stubs(:read).with(Usage::CGROUP_V1_QUOTA).returns(nil)
    Usage.stubs(:read).with(Usage::CGROUP_V1_PERIOD).returns(nil)
    Usage.stubs(:read).with(Usage::CEDAR_MEMORY_LIMIT).returns("536870912")
    assert_equal 1.0, Usage.available_cpus
  end

  def test_cedar_shared_2x_entitlement_from_memory_fingerprint
    ENV["DYNO"] = "worker.1"
    Usage.stubs(:read).returns(nil)
    Usage.stubs(:read).with(Usage::CEDAR_MEMORY_LIMIT).returns("1073741824")
    assert_equal 2.0, Usage.available_cpus
  end

  def test_cedar_dedicated_fingerprint_falls_through_to_processor_count
    ENV["DYNO"] = "web.1"
    Usage.stubs(:read).returns(nil)
    Usage.stubs(:read).with(Usage::CEDAR_MEMORY_LIMIT).returns("2684354560")
    assert_equal Etc.nprocessors, Usage.available_cpus
  end

  def test_entitlement_ignored_off_heroku
    Usage.stubs(:read).returns(nil)
    Usage.stubs(:read).with(Usage::CEDAR_MEMORY_LIMIT).returns("536870912")
    assert_equal Etc.nprocessors, Usage.available_cpus
  end

  def test_heroku_entitlement_without_a_readable_memory_limit_falls_through
    ENV["DYNO"] = "web.1"
    Usage.stubs(:read).returns(nil)
    Usage.stubs(:read).with(Usage::CEDAR_MEMORY_LIMIT).returns(nil)
    assert_equal Etc.nprocessors, Usage.available_cpus
  end

  def test_cgroup_quota_wins_over_entitlement
    ENV["DYNO"] = "web-5fb9c979-lft2l"
    Usage.stubs(:read).returns(nil)
    Usage.stubs(:read).with(Usage::CGROUP_V2_QUOTA).returns("90000 100000")
    Usage.stubs(:read).with(Usage::CEDAR_MEMORY_LIMIT).returns("536870912")
    assert_in_delta 0.9, Usage.available_cpus, 0.0001
  end

  def test_render_entitlement_from_render_cpu_count
    ENV["RENDER"] = "true"
    ENV["RENDER_CPU_COUNT"] = "0.5"
    Usage.stubs(:read).returns(nil)
    assert_in_delta 0.5, Usage.available_cpus, 0.0001
  end

  def test_render_entitlement_ignored_off_render
    ENV["RENDER_CPU_COUNT"] = "8"
    Usage.stubs(:read).returns(nil)
    assert_equal Etc.nprocessors, Usage.available_cpus
  end

  def test_render_without_a_cpu_count_falls_through_to_processor_count
    ENV["RENDER"] = "true"
    Usage.stubs(:read).returns(nil)
    assert_equal Etc.nprocessors, Usage.available_cpus
  end

  def test_render_cpu_count_zero_or_non_numeric_falls_through
    ENV["RENDER"] = "true"
    Usage.stubs(:read).returns(nil)

    ENV["RENDER_CPU_COUNT"] = "0"
    assert_equal Etc.nprocessors, Usage.available_cpus

    ENV["RENDER_CPU_COUNT"] = "nope"
    assert_equal Etc.nprocessors, Usage.available_cpus
  end

  def test_cgroup_quota_wins_over_render_entitlement
    ENV["RENDER"] = "true"
    ENV["RENDER_CPU_COUNT"] = "8"
    Usage.stubs(:read).returns(nil)
    Usage.stubs(:read).with(Usage::CGROUP_V2_QUOTA).returns("50000 100000")
    assert_in_delta 0.5, Usage.available_cpus, 0.0001
  end

  def test_read_returns_stripped_file_contents
    Tempfile.create("usage") do |file|
      file.write(" 42\n")
      file.flush
      assert_equal "42", Usage.read(file.path)
    end
  end

  def test_read_returns_nil_for_missing_path
    assert_nil Usage.read("/nonexistent/cgroup/file")
  end

  def test_read_returns_nil_when_the_file_disappears_between_check_and_read
    File.stubs(:readable?).returns(true)
    File.stubs(:read).raises(Errno::ENOENT)
    assert_nil Usage.read("/proc/1/stat")
  end

  def test_clock_ticks_reads_sysconf
    ticks = Usage.clock_ticks
    assert_kind_of Integer, ticks
    assert_operator ticks, :>, 0
  end

  def test_clock_ticks_falls_back_to_100
    Etc.stubs(:sysconf).raises(NotImplementedError)
    assert_equal 100, Usage.clock_ticks
  end

  def test_positive_clock_ticks_rejects_zero_and_negative
    Usage.stubs(:clock_ticks).returns(0)
    assert_equal 100, Usage.positive_clock_ticks

    Usage.stubs(:clock_ticks).returns(-5)
    assert_equal 100, Usage.positive_clock_ticks

    Usage.stubs(:clock_ticks).returns(250)
    assert_equal 250, Usage.positive_clock_ticks
  end

  def test_cgroup_v2_without_a_usage_usec_line_falls_through_to_v1
    Usage.stubs(:read).returns(nil)
    Usage.stubs(:read).with(Usage::CGROUP_V2_USAGE).returns("user_usec 1000000\nsystem_usec 500000")
    Usage.stubs(:read).with(Usage::CGROUP_V1_USAGE).returns("3000000000")

    assert_in_delta 3.0, Usage.total_seconds, 0.0001
  end

  def test_available_cpus_ignores_v1_unlimited_quota
    Usage.stubs(:read).returns(nil)
    Usage.stubs(:read).with(Usage::CGROUP_V1_QUOTA).returns("-1")
    Usage.stubs(:read).with(Usage::CGROUP_V1_PERIOD).returns("100000")

    assert_equal Etc.nprocessors, Usage.available_cpus
  end

  def test_stat_ticks_returns_nil_for_a_line_without_a_comm_paren
    assert_nil Usage.stat_ticks("123 ruby S 0 1 1 0")
  end

  def test_stat_ticks_returns_nil_for_a_truncated_line
    assert_nil Usage.stat_ticks("123 (ruby) S 0 1")
  end

  def test_stat_ticks_returns_nil_for_non_numeric_fields
    assert_nil Usage.stat_ticks("1 (ruby) S 0 1 1 0 -1 0 0 0 0 0 abc def 0 0 20 0 1 0 9 0 0")
  end

  def test_proc_namespace_seconds_nil_when_every_entry_is_unreadable
    Dir.stubs(:glob).with(Usage::PROC_STAT_GLOB).returns(["/proc/1/stat", "/proc/2/stat"])
    Usage.stubs(:read).with("/proc/1/stat").returns(nil)
    Usage.stubs(:read).with("/proc/2/stat").returns(nil)

    assert_nil Usage.proc_namespace_seconds
  end

  def test_a_garbled_proc_stat_entry_is_skipped_and_the_rest_counted
    Dir.stubs(:glob).with(Usage::PROC_STAT_GLOB).returns(["/proc/1/stat", "/proc/2/stat"])
    Usage.stubs(:read).with("/proc/1/stat").returns("1 (ruby) S 0 1 1 0 -1 0 0 0 0 0 500 250 0 0 20 0 1 0 9 0 0")
    Usage.stubs(:read).with("/proc/2/stat").returns("2 garbled line without a comm paren")
    Usage.stubs(:clock_ticks).returns(100)

    assert_in_delta 7.5, Usage.proc_namespace_seconds, 0.0001
  end
end
