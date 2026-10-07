# frozen_string_literal: true

require_relative "../../test/hirefire/macro/test_sidekiq"

class SidekiqEvidence < HireFire::Macro::SidekiqTest
  def test_evidence_max_scheduled_caps_the_count_without_queue_names
    5.times { enqueue_scheduled(queue: "default", at: Time.now.to_i - 60) }
    options = {max_scheduled: 2, skip_retries: true, skip_working: true}

    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(server: true, **options)
    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(:default, **options)
    assert_equal 2, HireFire::Macro::Sidekiq.job_queue_size(**options)
  end

  def test_evidence_an_enqueued_at_in_integer_seconds_is_not_read_as_1970
    payload = JSON.generate("class" => "BasicJob", "args" => [], "queue" => "default", "jid" => "a" * 24, "enqueued_at" => Time.now.to_i - 30)
    Sidekiq.redis do |connection|
      connection.call("sadd", "queues", "default")
      connection.call("lpush", "queue:default", payload)
    end

    assert_in_delta 30, HireFire::Macro::Sidekiq.job_queue_latency(:default, skip_retries: true, skip_scheduled: true), 5
  end

  def test_evidence_a_named_queue_size_over_the_walk_budget_still_reports_a_number
    score = Time.now.to_f - 60
    Sidekiq.redis do |connection|
      60.times do |batch|
        members = Array.new(1_000) { |index| [score, JSON.generate("class" => "BasicJob", "args" => [], "queue" => "default", "jid" => "#{batch}-#{index}")] }.flatten
        connection.call("zadd", "schedule", *members)
      end
    end

    size = HireFire::Macro::Sidekiq.job_queue_size(:default, skip_retries: true, skip_working: true)
    assert_operator size, :>=, 50_000
  end
end
