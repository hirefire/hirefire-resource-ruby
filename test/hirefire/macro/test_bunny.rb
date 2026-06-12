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

  def test_job_queue_size_with_missing_queue_raises_not_found
    # A passive declare of a missing queue makes the broker close the channel
    # (404). The real Bunny::NotFound must propagate rather than be masked by a
    # Bunny::ChannelAlreadyClosed raised while closing the already-closed channel.
    queue_name = "missing_#{rand(1_000_000)}"
    assert_raises Bunny::NotFound do
      HireFire::Macro::Bunny.job_queue_size(queue_name, amqp_url: AMQP_URL)
    end
  end

  def test_job_queue_size_reuses_provided_connection
    connection = ::Bunny.new(AMQP_URL).tap(&:start)

    with_connection(queue: :reuse_queue, durable: true) do |_conn, _channel, queue|
      queue.publish(TEST_MESSAGE)

      # The provided connection is reused (not reopened) and left open across calls.
      assert_equal 1, HireFire::Macro::Bunny.job_queue_size(:reuse_queue, connection: connection)
      assert connection.open?, "provided connection must stay open for reuse"
      assert_equal 1, HireFire::Macro::Bunny.job_queue_size(:reuse_queue, connection: connection)
      assert connection.open?
    end
  ensure
    connection&.close
  end

  def test_reused_connection_survives_missing_queue_error
    connection = ::Bunny.new(AMQP_URL).tap(&:start)

    assert_raises ::Bunny::NotFound do
      HireFire::Macro::Bunny.job_queue_size("missing_#{rand(1_000_000)}", connection: connection)
    end

    # A 404 closes only the channel; a reused connection must remain usable.
    assert connection.open?, "a channel-level 404 must not close a reused connection"
  ensure
    connection&.close
  end

  def test_connection_close_failure_does_not_mask_body_error
    # If connection.close raises (e.g. broken socket), it must not replace the
    # real error raised by the body (here, NotFound from the missing queue).
    ::Bunny::Session.any_instance.stubs(:close).raises(::Bunny::Exception.new("close boom"))
    queue_name = "missing_#{rand(1_000_000)}"
    assert_raises ::Bunny::NotFound do
      HireFire::Macro::Bunny.job_queue_size(queue_name, amqp_url: AMQP_URL)
    end
  end

  def test_setup_channel_closes_connection_when_channel_creation_fails
    # create_channel runs before the begin/ensure, so a failure there must not
    # leak the open connection.
    connection = mock("connection")
    connection.stubs(:start)
    connection.stubs(:create_channel).raises(::Bunny::Exception.new("channel boom"))
    connection.expects(:close).at_least_once
    ::Bunny.stubs(:new).returns(connection)

    assert_raises ::Bunny::Exception do
      HireFire::Macro::Bunny.job_queue_size(:default, amqp_url: AMQP_URL)
    end
  end

  def test_borrowed_connection_is_not_closed_when_channel_creation_fails
    # A caller-supplied connection is never closed by the macro, even when
    # opening the channel fails — the caller owns its lifecycle.
    connection = mock("connection")
    connection.stubs(:create_channel).raises(::Bunny::Exception.new("channel boom"))
    connection.expects(:close).never

    assert_raises ::Bunny::Exception do
      HireFire::Macro::Bunny.job_queue_size(:default, connection: connection)
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
