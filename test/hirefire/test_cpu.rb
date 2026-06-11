# frozen_string_literal: true

require "test_helper"

class HireFire::CPUTest < Minitest::Test
  def buffer
    HireFire.configuration.buffer
  end

  def test_first_sample_only_seeds_the_baseline
    HireFire::CPU::Usage.stubs(:total_seconds).returns(10.0)
    HireFire::CPU::Usage.stubs(:available_cpus).returns(1.0)

    collector = HireFire::CPU.new("clock")
    Timecop.freeze(Time.at(1000)) { assert_nil collector.sample }
    assert_empty buffer.flush[:cpu]
  end

  def test_second_sample_buffers_normalized_percentage
    HireFire::CPU::Usage.stubs(:total_seconds).returns(10.0, 10.5)
    HireFire::CPU::Usage.stubs(:available_cpus).returns(1.0)

    collector = HireFire::CPU.new("clock")
    Timecop.freeze(Time.at(1000)) { collector.sample }
    Timecop.freeze(Time.at(1001)) { collector.sample }

    # 0.5 CPU-seconds consumed over 1 wall-second on 1 available CPU => 50%.
    assert_equal({"clock" => {1001 => [50.0]}}, buffer.flush[:cpu])
  end

  def test_normalizes_by_available_cpus
    HireFire::CPU::Usage.stubs(:total_seconds).returns(0.0, 1.0)
    HireFire::CPU::Usage.stubs(:available_cpus).returns(4.0)

    collector = HireFire::CPU.new("worker")
    Timecop.freeze(Time.at(1000)) { collector.sample }
    Timecop.freeze(Time.at(1001)) { collector.sample }

    # 1 CPU-second over 1s on 4 CPUs => 25%.
    assert_equal({"worker" => {1001 => [25.0]}}, buffer.flush[:cpu])
  end

  def test_clamps_to_100_percent
    HireFire::CPU::Usage.stubs(:total_seconds).returns(0.0, 5.0)
    HireFire::CPU::Usage.stubs(:available_cpus).returns(1.0)

    collector = HireFire::CPU.new("clock")
    Timecop.freeze(Time.at(1000)) { collector.sample }
    Timecop.freeze(Time.at(1001)) { collector.sample }

    assert_equal({"clock" => {1001 => [100.0]}}, buffer.flush[:cpu])
  end

  def test_skips_sample_when_usage_unavailable
    HireFire::CPU::Usage.stubs(:total_seconds).returns(nil)
    HireFire::CPU::Usage.stubs(:available_cpus).returns(1.0)

    collector = HireFire::CPU.new("clock")
    Timecop.freeze(Time.at(1000)) { collector.sample }
    Timecop.freeze(Time.at(1001)) { assert_nil collector.sample }
    assert_empty buffer.flush[:cpu]
  end
end

class HireFire::CPU::UsageTest < Minitest::Test
  Usage = HireFire::CPU::Usage

  def test_total_seconds_prefers_cgroup_v2
    Usage.stubs(:read).with(Usage::CGROUP_V2_USAGE).returns("usage_usec 2500000\nuser_usec 1000000")
    assert_in_delta 2.5, Usage.total_seconds, 0.0001
  end

  def test_total_seconds_falls_back_to_cgroup_v1
    Usage.stubs(:read).with(Usage::CGROUP_V2_USAGE).returns(nil)
    Usage.stubs(:read).with(Usage::CGROUP_V1_USAGE).returns("3000000000")
    assert_in_delta 3.0, Usage.total_seconds, 0.0001
  end

  def test_total_seconds_falls_back_to_proc_namespace_sum
    Usage.stubs(:read).with(Usage::CGROUP_V2_USAGE).returns(nil)
    Usage.stubs(:read).with(Usage::CGROUP_V1_USAGE).returns(nil)
    Dir.stubs(:glob).with(Usage::PROC_STAT_GLOB).returns(["/proc/1/stat", "/proc/2/stat"])
    Usage.stubs(:read).with("/proc/1/stat").returns("1 (ruby) S 0 1 1 0 -1 0 0 0 0 0 500 250 0 0 20 0 1 0 9 0 0")
    Usage.stubs(:read).with("/proc/2/stat").returns("2 (puma (worker)) S 1 1 1 0 -1 0 0 0 0 0 150 100 0 0 20 0 1 0 9 0 0")
    Usage.stubs(:clock_ticks).returns(100)

    # (500+250) + (150+100) = 1000 ticks / 100 = 10.0 seconds, whole-dyno.
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
    Usage.stubs(:read).with(Usage::CEDAR_MEMORY_LIMIT).returns("2684354560") # performance-m
    assert_equal Etc.nprocessors, Usage.available_cpus
  end

  def test_entitlement_ignored_off_heroku
    Usage.stubs(:read).returns(nil)
    Usage.stubs(:read).with(Usage::CEDAR_MEMORY_LIMIT).returns("536870912")
    assert_equal Etc.nprocessors, Usage.available_cpus
  end

  def test_cgroup_quota_wins_over_entitlement
    ENV["DYNO"] = "web-5fb9c979-lft2l"
    Usage.stubs(:read).returns(nil)
    Usage.stubs(:read).with(Usage::CGROUP_V2_QUOTA).returns("90000 100000") # Fir 1c plan
    Usage.stubs(:read).with(Usage::CEDAR_MEMORY_LIMIT).returns("536870912")
    assert_in_delta 0.9, Usage.available_cpus, 0.0001
  end
end
