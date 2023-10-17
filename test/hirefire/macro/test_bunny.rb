# frozen_string_literal: true

require "test_helper"

class HireFire::Macro::BunnyTest < Minitest::Test
  AMQP_URL = "amqp://guest:guest@localhost:5672"
  TEST_MESSAGE = "Test Message"

  def test_missing_queues_raises_error
    assert_raises HireFire::Errors::MissingQueueError do
      HireFire::Macro::Bunny.job_queue_size(ampq_url: AMQP_URL)
    end
  end

  def test_missing_connection_and_amqp_url_raises_error
    assert_raises HireFire::Macro::Bunny::ConnectionError do
      HireFire::Macro::Bunny.job_queue_size(:default)
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
        assert_equal 1, HireFire::Macro::Bunny.job_queue_size(:default, amqp_url: AMQP_URL, durable: false)
        assert_equal 2, HireFire::Macro::Bunny.job_queue_size(:default, :mailer, amqp_url: AMQP_URL, durable: false)
      end
    end
  end

  def test_job_queue_size_with_jobs_using_connection
    with_connection(queue: :default) do |connection, channel, default|
      with_connection(queue: :mailer) do |connection, channel, mailer|
        [default, mailer].each { |queue| queue.publish(TEST_MESSAGE) }
        assert_equal 1, HireFire::Macro::Bunny.job_queue_size(:default, connection: connection, durable: false)
        assert_equal 2, HireFire::Macro::Bunny.job_queue_size(:default, :mailer, connection: connection, durable: false)
      end
    end
  end

  def test_job_queue_size_with_jobs_using_durable
    with_connection(durable: true) do |connection, channel, queue|
      queue.publish(TEST_MESSAGE)
      assert queue.options[:durable]
      assert_equal 1, HireFire::Macro::Bunny.job_queue_size(queue.name, connection: connection)
    end
  end

  def test_job_queue_size_with_jobs_using_max_priority
    max_priority = 10

    with_connection(max_priority: max_priority) do |connection, channel, queue|
      0.upto(9).each { |n| queue.publish(TEST_MESSAGE, priority: n) }
      assert_equal 10, queue.arguments["x-max-priority"]
      assert_equal 10, HireFire::Macro::Bunny.job_queue_size(
        queue.name,
        connection: connection,
        durable: false,
        max_priority: max_priority
      )
    end
  end

  def test_count_with_jobs_using_legacy_max_priority
    max_priority = 10

    with_connection(max_priority: max_priority) do |connection, channel, queue|
      0.upto(9).each { |n| queue.publish(TEST_MESSAGE, priority: n) }
      assert_equal 10, queue.arguments["x-max-priority"]
      assert_equal 10, HireFire::Macro::Bunny.job_queue_size(
        queue.name,
        connection: connection,
        durable: false,
        "x-max-priority": max_priority
      )
    end
  end

  private

  # Establishes a connection to the RabbitMQ server and opens a channel.
  # A queue with the specified options is then declared on this channel.
  # This method is used to setup and teardown connection for test cases.
  #
  # @param options [Hash] the options for configuring the connection and queue.
  # @option options [String, Symbol] :queue (default) the name of the queue.
  # @option options [Boolean] :durable (false) whether the queue should be durable.
  # @option options [Integer] :max_priority (nil) the maximum priority the queue should support.
  # @yield [connection, channel, queue] Gives a connected RabbitMQ connection, channel, and declared queue to the block.
  # @yieldparam connection [Bunny::Session] the established RabbitMQ connection.
  # @yieldparam channel [Bunny::Channel] the opened RabbitMQ channel.
  # @yieldparam queue [Bunny::Queue] the declared RabbitMQ queue.
  # @return [void]
  #
  def with_connection(options = {})
    connection = ::Bunny.new(AMQP_URL)
    connection.start
    channel = connection.create_channel

    queue_name = options.fetch(:queue, "default").to_s
    durable = options.fetch(:durable, false)
    max_priority = options[:max_priority]

    queue_args = {}
    queue_args["x-max-priority"] = max_priority if max_priority

    queue = channel.queue(queue_name, durable: durable, arguments: queue_args)

    yield connection, channel, queue
  ensure
    channel.queue_delete(queue_name) if channel && queue_name
    channel&.close
    connection&.close
  end
end
