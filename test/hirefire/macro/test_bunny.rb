# frozen_string_literal: true

require "test_helper"

class HireFire::Macro::BunnyTest < Minitest::Test
  AMQP_URL = "amqp://guest:guest@localhost:5672"
  TEST_MESSAGE = "Test Message"

  def test_missing_queues_raises_error
    assert_raises HireFire::Errors::MissingQueueError do
      HireFire::Macro::Bunny.job_queue_size
    end
  end

  def test_job_queue_latency_unsupported_raises_error
    assert_raises HireFire::Errors::JobQueueLatencyUnsupportedError do
      HireFire::Macro::Bunny.job_queue_latency(:default)
    end
  end

  def test_job_queue_size_with_jobs_using_amqp_url
    with_connection(queue: :default) do |connection, channel, default|
      with_connection(queue: :mailer) do |connection, channel, mailer|
        [default, mailer].each { |queue| queue.publish(TEST_MESSAGE) }
        assert_equal 1, HireFire::Macro::Bunny.job_queue_size(:default, amqp_url: AMQP_URL)
        assert_equal 2, HireFire::Macro::Bunny.job_queue_size(:default, :mailer, amqp_url: AMQP_URL)
      end
    end
  end

  def test_job_queue_size_with_jobs_using_durable
    with_connection(durable: true) do |connection, channel, queue|
      queue.publish(TEST_MESSAGE)
      assert queue.options[:durable]
      assert_equal 1, HireFire::Macro::Bunny.job_queue_size(queue.name)
    end
  end

  def test_job_queue_size_with_jobs_using_max_priority
    max_priority = 10

    with_connection(max_priority: max_priority) do |connection, channel, queue|
      0.upto(9).each { |n| queue.publish(TEST_MESSAGE, priority: n) }
      assert_equal 10, queue.arguments["x-max-priority"]
      assert_equal 10, HireFire::Macro::Bunny.job_queue_size(queue.name)
    end
  end

  def test_deprecated_queue_method
    with_connection(queue: :default_legacy, durable: true) do |connection, channel, default|
      with_connection(queue: :mailer_legacy, durable: true) do |connection, channel, mailer|
        [default, mailer].each { |queue| queue.publish(TEST_MESSAGE) }
        assert_equal 1, HireFire::Macro::Bunny.queue(:default_legacy, amqp_url: AMQP_URL)
        assert_equal 2, HireFire::Macro::Bunny.queue(:default_legacy, :mailer_legacy, connection: connection)
      end
    end
  end

  private

  def with_connection(options = {})
    connection = ::Bunny.new(AMQP_URL)
    connection.start
    channel = connection.create_channel

    queue_name = options.fetch(:queue, "default").to_s
    durable = options.fetch(:durable, false)
    max_priority = options[:max_priority]

    queue_args = {}
    queue_args["x-max-priority"] = max_priority if max_priority

    channel.queue_delete(queue_name)
    queue = channel.queue(queue_name, durable: durable, arguments: queue_args)

    yield connection, channel, queue
  ensure
    channel.queue_delete(queue_name) if channel && queue_name
    channel&.close
    connection&.close
  end
end
