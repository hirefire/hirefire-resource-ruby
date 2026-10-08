# frozen_string_literal: true

require "test_helper"

class HireFire::ConstantsTest < Minitest::Test
  def test_the_limits_and_defaults_have_the_values_the_specification_gives
    usage = HireFire::Source::CPU::Usage
    assert_equal(
      {
        "Buffer::SAMPLE_COUNT_LIMIT" => 1_000_000,
        "Client::TIMEOUT" => 5,
        "Client::MAX_BODY_BYTES" => 131_072,
        "Client::DEFAULT_URL" => "https://data.hirefire.io",
        "Dispatcher::RQT_BACKFILL_LIMIT" => 60,
        "Dispatcher::PAYLOAD_SIZE_LIMIT" => 131_072,
        "Dispatcher::METRIC_VALUE_LIMIT" => 1e15,
        "Dispatcher::DEFAULT_DISPATCH_FREQUENCY" => 1,
        "Dispatcher::MAX_DISPATCH_FREQUENCY" => 30,
        "Dispatcher::BACKOFF_DOUBLINGS" => 5,
        "Dispatcher::FAILURE_LOG_INTERVAL" => 60,
        "Dispatcher::SAMPLE_ROUND_LIMIT" => 60,
        "Dispatcher::JOIN_TIMEOUT" => 5,
        "Dispatcher::TICK" => 1,
        "Identity::MAX_NAME_BYTES" => 128,
        "Identity::ONE_OFF_DYNOS" => %w[run release],
        "Lease::TTL_BOUNDS" => 5..3600,
        "Lease::SAMPLE_FREQUENCY_BOUNDS" => 1..3600,
        "Lease::MAX_JOB_QUEUES" => 256,
        "Middleware::REQUEST_QUEUE_TIME_LIMIT" => 60_000,
        "Once::LIMIT" => 256,
        "Plan::MAX_QUEUES" => 64,
        "Plan::MAX_QUEUE_NAME_BYTES" => 128,
        "Source::CPU::Usage paths" => [
          "/sys/fs/cgroup/cpu.stat", "/sys/fs/cgroup/cpuacct/cpuacct.usage", "/sys/fs/cgroup/cpu.max",
          "/sys/fs/cgroup/cpu/cpu.cfs_quota_us", "/sys/fs/cgroup/cpu/cpu.cfs_period_us",
          "/sys/fs/cgroup/memory/memory.limit_in_bytes", "/proc/[0-9]*/stat"
        ],
        "Source::CPU::Usage::CEDAR_SHARED_ENTITLEMENTS" => {536_870_912 => 1.0, 1_073_741_824 => 2.0},
        "Strategy names" => %w[rqt jql jqs cpu wrk]
      },
      {
        "Buffer::SAMPLE_COUNT_LIMIT" => HireFire::Buffer::SAMPLE_COUNT_LIMIT,
        "Client::TIMEOUT" => HireFire::Client::TIMEOUT,
        "Client::MAX_BODY_BYTES" => HireFire::Client::MAX_BODY_BYTES,
        "Client::DEFAULT_URL" => HireFire::Client::DEFAULT_URL,
        "Dispatcher::RQT_BACKFILL_LIMIT" => HireFire::Dispatcher::RQT_BACKFILL_LIMIT,
        "Dispatcher::PAYLOAD_SIZE_LIMIT" => HireFire::Dispatcher::PAYLOAD_SIZE_LIMIT,
        "Dispatcher::METRIC_VALUE_LIMIT" => HireFire::Dispatcher::METRIC_VALUE_LIMIT,
        "Dispatcher::DEFAULT_DISPATCH_FREQUENCY" => HireFire::Dispatcher::DEFAULT_DISPATCH_FREQUENCY,
        "Dispatcher::MAX_DISPATCH_FREQUENCY" => HireFire::Dispatcher::MAX_DISPATCH_FREQUENCY,
        "Dispatcher::BACKOFF_DOUBLINGS" => HireFire::Dispatcher::BACKOFF_DOUBLINGS,
        "Dispatcher::FAILURE_LOG_INTERVAL" => HireFire::Dispatcher::FAILURE_LOG_INTERVAL,
        "Dispatcher::SAMPLE_ROUND_LIMIT" => HireFire::Dispatcher::SAMPLE_ROUND_LIMIT,
        "Dispatcher::JOIN_TIMEOUT" => HireFire::Dispatcher::JOIN_TIMEOUT,
        "Dispatcher::TICK" => HireFire::Dispatcher::TICK,
        "Identity::MAX_NAME_BYTES" => HireFire::Identity::MAX_NAME_BYTES,
        "Identity::ONE_OFF_DYNOS" => HireFire::Identity::ONE_OFF_DYNOS,
        "Lease::TTL_BOUNDS" => HireFire::Lease::TTL_BOUNDS,
        "Lease::SAMPLE_FREQUENCY_BOUNDS" => HireFire::Lease::SAMPLE_FREQUENCY_BOUNDS,
        "Lease::MAX_JOB_QUEUES" => HireFire::Lease::MAX_JOB_QUEUES,
        "Middleware::REQUEST_QUEUE_TIME_LIMIT" => HireFire::Middleware::REQUEST_QUEUE_TIME_LIMIT,
        "Once::LIMIT" => HireFire::Once::LIMIT,
        "Plan::MAX_QUEUES" => HireFire::Plan::MAX_QUEUES,
        "Plan::MAX_QUEUE_NAME_BYTES" => HireFire::Plan::MAX_QUEUE_NAME_BYTES,
        "Source::CPU::Usage paths" => [
          usage::CGROUP_V2_USAGE, usage::CGROUP_V1_USAGE, usage::CGROUP_V2_QUOTA, usage::CGROUP_V1_QUOTA, usage::CGROUP_V1_PERIOD,
          usage::CEDAR_MEMORY_LIMIT, usage::PROC_STAT_GLOB
        ],
        "Source::CPU::Usage::CEDAR_SHARED_ENTITLEMENTS" => usage::CEDAR_SHARED_ENTITLEMENTS,
        "Strategy names" => [HireFire::Strategy::RQT, HireFire::Strategy::JQL, HireFire::Strategy::JQS, HireFire::Strategy::CPU, HireFire::Strategy::WRK]
      }
    )
  end
end
