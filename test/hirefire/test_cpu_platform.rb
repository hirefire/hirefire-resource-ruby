# frozen_string_literal: true

require "test_helper"

# Closed-world platform goldens for HireFire::Source::CPU::Usage.
# Fixture bodies are verbatim extracts from hirefire-resource/cpu-platform-samples.md
# (capture date 2026-07-27). Do not invent platform samples here.
class HireFire::Source::CPU::PlatformTest < Minitest::Test
  Usage = HireFire::Source::CPU::Usage
  FIXTURE_ROOT = File.expand_path("../../fixtures/cpu", __FILE__)

  # Loud default so host Etc.nprocessors never becomes a silent entitlement.
  # Capture-meta nproc values (shared 8, Perf 2/8/4/8/16, Fir 48/96, Render 8/32)
  # are documented in comments only; tests that care pass an explicit nproc:.
  NPROC_SENTINEL = 97

  # Cedar Performance / Private / Shield non-fingerprint sizes. Limits are real
  # capture bodies (2026-07-27). Live nproc was M=2, L=8, L-RAM=4, XL=8, 2XL=16;
  # tests stub NPROC_SENTINEL so a missed fingerprint still proves map-miss fallthrough.
  CEDAR_DEDICATED = %w[
    performance_m
    performance_l
    performance_l_ram
    performance_xl
    performance_2xl
  ].freeze

  FIR_CPU_MAX = [
    ["dyno_1c_0_5gb_cpu_max.txt", 0.9],
    ["cpu_max_2c.txt", 1.8],
    ["cpu_max_4c.txt", 3.6],
    ["cpu_max_8c.txt", 7.2],
    ["cpu_max_16c.txt", 14.4],
    ["cpu_max_32c.txt", 28.8]
  ].freeze

  RENDER_PLAN_MATRIX = [
    ["free_cpu_max.txt", 0.15],
    ["starter_cpu_max.txt", 0.5],
    ["standard_cpu_max.txt", 1.0],
    ["pro_cpu_max.txt", 2.0],
    ["pro_plus_cpu_max.txt", 4.0],
    ["pro_max_cpu_max.txt", 4.0],
    ["pro_ultra_cpu_max.txt", 8.0]
  ].freeze

  RENDER_CPU_COUNT_STRINGS = [
    ["0.15", 0.15],
    ["0.50", 0.5],
    ["1", 1.0],
    ["8", 8.0]
  ].freeze

  DELTA = 0.0001

  def fixture(relative_path)
    path = File.join(FIXTURE_ROOT, relative_path)
    File.read(path).lines.reject { |line| line.start_with?("#") }.join.strip
  end

  # Default every Usage.read → nil (no host /proc or cgroup leak), then inject
  # only the fixture map. Dir.glob never sees the real host. process_seconds is
  # nil so usage never falls through to the process clock unless a test re-stubs.
  # processor_count always stubs (default NPROC_SENTINEL).
  def closed_world(reads: {}, proc_paths: [], nproc: NPROC_SENTINEL, clock_ticks: 100)
    Usage.stubs(:read).returns(nil)
    reads.each do |path, content|
      Usage.stubs(:read).with(path).returns(content)
    end
    Dir.stubs(:glob).with(Usage::PROC_STAT_GLOB).returns(Array(proc_paths))
    Usage.stubs(:clock_ticks).returns(clock_ticks)
    Usage.stubs(:processor_count).returns(nproc)
    Usage.stubs(:process_seconds).returns(nil)
  end

  # --- Cedar (Heroku classic): entitlement ---

  def test_cedar_basic_1x_fingerprint_not_host_nproc
    ENV["DYNO"] = "web.1"
    # Capture nproc on shared Basic/1X was 8 (host). Fingerprint must win.
    closed_world(
      reads: {Usage::CEDAR_MEMORY_LIMIT => fixture("cedar/memory_limit_basic.txt")},
      nproc: 8
    )

    assert_in_delta 1.0, Usage.available_cpus, DELTA
  end

  def test_cedar_standard_2x_fingerprint_not_host_nproc
    ENV["DYNO"] = "web.1"
    closed_world(
      reads: {Usage::CEDAR_MEMORY_LIMIT => fixture("cedar/memory_limit_standard_2x.txt")},
      nproc: 8
    )

    assert_in_delta 2.0, Usage.available_cpus, DELTA
  end

  def test_cedar_performance_dedicated_fingerprint_miss_falls_to_nproc
    # Real limits from Performance (and matching Private/Shield) captures.
    # Expects prove CEDAR_MEMORY_LIMIT is read (fixture applied). NPROC_SENTINEL
    # proves the body is not in CEDAR_SHARED_ENTITLEMENTS (map miss → fallthrough).
    # Unread limit alone would also fall through to 97 without the expects.
    CEDAR_DEDICATED.each do |name|
      ENV["DYNO"] = "web.1"
      body = fixture("cedar/memory_limit_#{name}.txt")
      closed_world(nproc: NPROC_SENTINEL)
      Usage.expects(:read).with(Usage::CEDAR_MEMORY_LIMIT).at_least_once.returns(body)

      assert_in_delta NPROC_SENTINEL.to_f, Usage.available_cpus, DELTA,
        "Cedar #{name}: limit not in fingerprint map must fall through to nproc"
    end
  end

  # Private-S and Shield-S share the 1 GiB Standard-2X fingerprint key
  # (cpu-platform-samples.md decision log: no Private/Shield special case).
  def test_cedar_private_s_and_shield_s_one_gib_fingerprint_no_space_special_case
    ENV["DYNO"] = "run.8256"
    # High nproc so only fingerprint yields 2.0 (live Private/Shield-S nproc is 2).
    closed_world(
      reads: {Usage::CEDAR_MEMORY_LIMIT => fixture("cedar/memory_limit_standard_2x.txt")},
      nproc: 8
    )

    assert_in_delta 2.0, Usage.available_cpus, DELTA
  end

  def test_cedar_dyno_unset_ignores_memory_fingerprint
    # DYNO cleared by test_helper. Shared 512 MiB limit must not fingerprint.
    closed_world(
      reads: {Usage::CEDAR_MEMORY_LIMIT => fixture("cedar/memory_limit_basic.txt")},
      nproc: 8
    )

    assert_in_delta 8.0, Usage.available_cpus, DELTA
  end

  # --- Cedar: /proc usage ---

  def test_cedar_basic_formation_puma_master_and_worker_proc_sum
    master = fixture("cedar/proc_basic_formation_puma_master.txt")
    worker = fixture("cedar/proc_basic_formation_puma_worker.txt")
    paths = ["/proc/2/stat", "/proc/50/stat"]

    closed_world(
      reads: {
        "/proc/2/stat" => master,
        "/proc/50/stat" => worker
      },
      proc_paths: paths,
      clock_ticks: 100
    )

    # PID2: 3793+1400=5193, PID50: 80+15=95 → 5288 ticks / 100 = 52.88
    seconds, source = Usage.reading
    assert_equal :proc, source
    assert_in_delta 52.88, seconds, DELTA
  end

  def test_cedar_oneoff_zero_tick_ps_run_stays_on_proc
    stat = fixture("cedar/proc_basic_oneoff_ps_run.txt")
    closed_world(
      reads: {"/proc/1/stat" => stat},
      proc_paths: ["/proc/1/stat"],
      clock_ticks: 100
    )
    # closed_world nulls process_seconds; re-stub high to prove no fallthrough.
    Usage.stubs(:process_seconds).returns(99.0)

    seconds, source = Usage.reading
    assert_equal :proc, source
    assert_in_delta 0.0, seconds, DELTA
  end

  # --- Fir (Heroku CNB) ---

  def test_fir_dyno_1c_0_5gb_cpu_stat_usage
    closed_world(
      reads: {Usage::CGROUP_V2_USAGE => fixture("fir/dyno_1c_0_5gb_cpu_stat.txt")}
    )

    seconds, source = Usage.reading
    assert_equal :cgroup_v2, source
    assert_in_delta 31_663 / 1_000_000.0, seconds, DELTA
  end

  def test_fir_cpu_max_beats_host_nproc
    ENV["DYNO"] = "run-nss86zptrv-7fpx8"
    # Capture host nproc was 96; trap with that value.
    closed_world(
      reads: {Usage::CGROUP_V2_QUOTA => fixture("fir/dyno_1c_0_5gb_cpu_max.txt")},
      nproc: 96
    )

    assert_in_delta 0.9, Usage.available_cpus, DELTA
  end

  def test_fir_parametric_unique_entitlements
    ENV["DYNO"] = "web-fir-1"
    FIR_CPU_MAX.each do |file, expected|
      closed_world(
        reads: {Usage::CGROUP_V2_QUOTA => fixture("fir/#{file}")},
        nproc: 96
      )

      assert_in_delta expected, Usage.available_cpus, DELTA,
        "Fir #{file} should yield #{expected}"
    end
  end

  def test_fir_dyno_set_with_cpu_max_does_not_use_cedar_memory_limit
    ENV["DYNO"] = "run-nss86zptrv-7fpx8"
    # Live Fir has no memory.limit_in_bytes path. Closed world leaves it nil.
    closed_world(
      reads: {Usage::CGROUP_V2_QUOTA => fixture("fir/dyno_1c_0_5gb_cpu_max.txt")},
      nproc: 96
    )

    assert_nil Usage.read(Usage::CEDAR_MEMORY_LIMIT)
    assert_in_delta 0.9, Usage.available_cpus, DELTA
  end

  # --- Render ---

  def test_render_starter_cpu_stat_usage
    closed_world(
      reads: {Usage::CGROUP_V2_USAGE => fixture("render/starter_cpu_stat.txt")}
    )

    seconds, source = Usage.reading
    assert_equal :cgroup_v2, source
    assert_in_delta 858_123 / 1_000_000.0, seconds, DELTA
  end

  def test_render_free_cpu_max_beats_marketing_0_1_env
    ENV["RENDER"] = "true"
    # Marketing/docs say 0.1; live Free cpu.max is 0.15. Env must not win.
    ENV["RENDER_CPU_COUNT"] = "0.1"
    closed_world(
      reads: {Usage::CGROUP_V2_QUOTA => fixture("render/free_cpu_max.txt")},
      nproc: 8
    )

    assert_in_delta 0.15, Usage.available_cpus, DELTA
  end

  def test_render_free_render_cpu_count_without_cgroup
    ENV["RENDER"] = "true"
    ENV["RENDER_CPU_COUNT"] = "0.15"
    closed_world(nproc: 8)

    assert_in_delta 0.15, Usage.available_cpus, DELTA
  end

  def test_render_full_plan_matrix_cpu_max
    ENV["RENDER"] = "true"
    # RENDER_CPU_COUNT left unset so only cpu.max can supply entitlement.
    RENDER_PLAN_MATRIX.each do |file, expected|
      closed_world(
        reads: {Usage::CGROUP_V2_QUOTA => fixture("render/#{file}")},
        nproc: 32
      )

      assert_in_delta expected, Usage.available_cpus, DELTA,
        "Render #{file} should yield #{expected}"
    end
  end

  def test_render_cpu_count_strings_without_cgroup
    ENV["RENDER"] = "true"
    RENDER_CPU_COUNT_STRINGS.each do |raw, expected|
      ENV["RENDER_CPU_COUNT"] = raw
      closed_world(nproc: 32)

      assert_in_delta expected, Usage.available_cpus, DELTA,
        "RENDER_CPU_COUNT=#{raw.inspect} should yield #{expected}"
    end
  end

  def test_render_quota_beats_misleading_render_cpu_count_low
    ENV["RENDER"] = "true"
    ENV["RENDER_CPU_COUNT"] = "0.1"
    closed_world(
      reads: {Usage::CGROUP_V2_QUOTA => fixture("render/starter_cpu_max.txt")},
      nproc: 8
    )

    assert_in_delta 0.5, Usage.available_cpus, DELTA
  end

  def test_render_quota_beats_misleading_render_cpu_count_high
    ENV["RENDER"] = "true"
    ENV["RENDER_CPU_COUNT"] = "8"
    closed_world(
      reads: {Usage::CGROUP_V2_QUOTA => fixture("render/starter_cpu_max.txt")},
      nproc: 8
    )

    assert_in_delta 0.5, Usage.available_cpus, DELTA
  end

  def test_render_pro_ultra_cpu_max_beats_host_nproc_32
    ENV["RENDER"] = "true"
    # RENDER_CPU_COUNT unset: only cpu.max can yield 8.0 against nproc trap 32.
    closed_world(
      reads: {Usage::CGROUP_V2_QUOTA => fixture("render/pro_ultra_cpu_max.txt")},
      nproc: 32
    )

    assert_in_delta 8.0, Usage.available_cpus, DELTA
  end
end
