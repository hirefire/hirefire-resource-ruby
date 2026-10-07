# frozen_string_literal: true

ROWS = Integer(ENV.fetch("AUDIT_ROWS", 1_000_000))
LIBRARY = ENV.fetch("AUDIT_LIBRARY")
QUEUE = "(ARRAY['default','mailers','low'])[1 + (i % 3)]"
DUE = "now() - interval '1 minute' - (i || ' milliseconds')::interval"

SEEDS = {
  "que" => ["INSERT INTO que_jobs (job_class, queue, run_at, job_schema_version) SELECT 'BasicJob', #{QUEUE}, #{DUE}, 2 FROM generate_series(1, #{ROWS}) AS i"],
  "delayed_job" => ["INSERT INTO delayed_jobs (priority, attempts, handler, run_at, queue, created_at, updated_at) SELECT 0, 0, '--- !ruby/object:BasicJob {}', #{DUE}, #{QUEUE}, now(), now() FROM generate_series(1, #{ROWS}) AS i"],
  "queue_classic" => ["INSERT INTO queue_classic_jobs (q_name, method, args, scheduled_at) SELECT #{QUEUE}, 'BasicJob.perform', '[]', #{DUE} FROM generate_series(1, #{ROWS}) AS i"],
  "solid_queue" => [
    "INSERT INTO solid_queue_jobs (queue_name, class_name, arguments, priority, active_job_id, created_at, updated_at) SELECT #{QUEUE}, 'BasicJob', '{}', 0, gen_random_uuid()::text, #{DUE}, now() FROM generate_series(1, #{ROWS}) AS i",
    "INSERT INTO solid_queue_ready_executions (job_id, queue_name, priority, created_at) SELECT id, queue_name, priority, created_at FROM solid_queue_jobs"
  ],
  "good_job" => ["INSERT INTO good_jobs (id, queue_name, priority, serialized_params, scheduled_at, created_at, updated_at, active_job_id, job_class) SELECT gen_random_uuid(), #{QUEUE}, 0, '{}', #{DUE}, #{DUE}, now(), gen_random_uuid(), 'BasicJob' FROM generate_series(1, #{ROWS}) AS i"]
}.freeze

TESTS = {
  "que" => ["test_que", "HireFire::Macro::QueTest", "HireFire::Macro::Que"],
  "delayed_job" => ["test_delayed_job", "HireFire::Macro::Delayed::JobTest", "HireFire::Macro::Delayed::Job"],
  "queue_classic" => ["test_queue_classic", "HireFire::Macro::QCTest", "HireFire::Macro::QC"],
  "solid_queue" => ["test_solid_queue", "HireFire::Macro::SolidQueueTest", "HireFire::Macro::SolidQueue"],
  "good_job" => ["test_good_job", "HireFire::Macro::GoodJobTest", "HireFire::Macro::GoodJob"]
}.freeze

file, parent, macro_name = TESTS.fetch(LIBRARY)
require_relative "../../test/hirefire/macro/#{file}"

Class.new(Object.const_get(parent)) do
  define_method(:test_evidence_sample_cost_on_a_large_backlog) do
    connection = ActiveRecord::Base.connection
    SEEDS.fetch(LIBRARY).each { |statement| connection.execute(statement) }
    connection.execute("ANALYZE")
    macro = Object.const_get(macro_name)
    calls = {
      "size, all queues" => -> { macro.job_queue_size },
      "size, one queue" => -> { macro.job_queue_size(:default) },
      "size without running jobs, one queue" => -> { macro.job_queue_size(:default, skip_working: true) },
      "latency, all queues" => -> { macro.job_queue_latency },
      "latency, one queue" => -> { macro.job_queue_latency(:default) },
      "working, one queue" => -> { macro.job_queue_working(:default) }
    }
    puts
    puts "#{LIBRARY}: #{ROWS} due jobs waiting in 3 queues, best of 3 calls"
    calls.each do |label, call|
      value = nil
      seconds = Array.new(3) do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        value = call.call
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      end.min
      puts format("  %-38s %8.1f ms  (value %s)", label, seconds * 1000, value.is_a?(Float) ? value.round(1) : value)
    end
    assert true
  end
end
