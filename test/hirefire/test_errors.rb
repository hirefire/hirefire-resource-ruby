# frozen_string_literal: true

require "test_helper"

class HireFire::ErrorsTest < Minitest::Test
  def test_job_queue_size_method_renamed_errors
    macros = [
      HireFire::Macro::Bunny,
      HireFire::Macro::Delayed::Job,
      HireFire::Macro::GoodJob,
      HireFire::Macro::Que,
      HireFire::Macro::QC,
      HireFire::Macro::Resque,
      HireFire::Macro::Sidekiq
    ]

    macros.each do |klass|
      assert_raises HireFire::Errors::QueueMethodRenamedError do
        klass.queue
      end
    end
  end

  def test_latency_method_renamed_errors
    macros = [
      HireFire::Macro::Delayed::Job,
      HireFire::Macro::GoodJob,
      HireFire::Macro::Que,
      HireFire::Macro::QC,
      HireFire::Macro::Sidekiq
    ]

    macros.each do |klass|
      assert_raises HireFire::Errors::LatencyMethodRenamedError do
        klass.latency
      end
    end
  end
end
