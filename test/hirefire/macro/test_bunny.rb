# frozen_string_literal: true

require "test_helper"
require "timeout"

ENV["AMQP_URL"] ||= "amqp://guest:guest@localhost:#{ENV.fetch("RABBITMQ_PORT", 5672)}"

class HireFire::Macro::BunnyTest < Minitest::Test
  AMQP_URL = ENV.fetch("AMQP_URL")
  TEST_MESSAGE = "Test Message"

  def test_library_loaded_is_true_when_bunny_gem_is_loaded
    assert HireFire::Plan.library_loaded?("bunny")
    assert HireFire::Plan.executable?("bunny")
    assert HireFire::Plan.any_allowlisted_job_queue_library_loaded?
  end

  def test_missing_queues_raises_error
    assert_raises HireFire::Errors::MissingQueueError do
      HireFire::Macro::Bunny.job_queue_size
    end
  end

  def test_does_not_define_job_queue_working
    refute HireFire::Macro::Bunny.respond_to?(:job_queue_working)
  end

  def test_supports_plan_strategy_size_only
    refute HireFire::Macro::Bunny.supports_plan_strategy?("jql")
    refute HireFire::Macro::Bunny.supports_plan_strategy?(:jql)
    assert HireFire::Macro::Bunny.supports_plan_strategy?("jqs")
    assert HireFire::Macro::Bunny.supports_plan_strategy?(:jqs)
    refute HireFire::Macro::Bunny.supports_plan_strategy?("rpm")
  end

  def test_job_queue_latency_unsupported_raises_error
    assert_raises HireFire::Errors::JobQueueLatencyUnsupportedError do
      HireFire::Macro::Bunny.job_queue_latency(:default)
    end
  end

  def test_job_queue_size_empty_ready_queue_is_zero
    with_connection(queue: :empty_ready) do |_connection, _channel, queue|
      assert_equal 0, HireFire::Macro::Bunny.job_queue_size(queue.name, amqp_url: AMQP_URL)
    end
  end

  def test_job_queue_size_with_jobs_using_amqp_url
    with_connection(queue: :default) do |_connection, channel, default|
      with_connection(queue: :mailer) do |_connection, mailer_channel, mailer|
        publish_confirmed(channel, default)
        publish_confirmed(mailer_channel, mailer)
        assert_size 1, :default, amqp_url: AMQP_URL
        assert_size 2, :default, :mailer, amqp_url: AMQP_URL
      end
    end
  end

  def test_job_queue_size_with_jobs_using_durable
    with_connection(durable: true) do |_connection, channel, queue|
      publish_confirmed(channel, queue)
      assert queue.options[:durable]
      assert_size 1, queue.name
    end
  end

  def test_job_queue_size_excludes_unacked
    with_connection(queue: :unacked) do |_connection, channel, queue|
      publish_confirmed(channel, queue)
      delivery_info, _properties, _payload = queue.pop(manual_ack: true)
      refute_nil delivery_info
      assert_size 0, queue.name, amqp_url: AMQP_URL
    end
  end

  def test_connection_kwarg_wins_over_amqp_url
    connection = ::Bunny.new(AMQP_URL).tap(&:start)

    with_connection(queue: :precedence, durable: true) do |_conn, channel, queue|
      publish_confirmed(channel, queue)
      assert_size 1, :precedence, connection: connection, amqp_url: "amqp://invalid.example:5672"
      assert connection.open?
    end
  ensure
    connection&.close
  end

  def test_job_queue_size_with_missing_queue_raises_not_found
    queue_name = "missing_#{rand(1_000_000)}"
    assert_raises Bunny::NotFound do
      HireFire::Macro::Bunny.job_queue_size(queue_name, amqp_url: AMQP_URL)
    end
  end

  def test_forked_child_drops_reused_connection_without_closing_parent
    skip "Process.fork unavailable" unless Process.respond_to?(:fork)
    skip "Process._fork unavailable" unless Process.respond_to?(:_fork)

    with_connection(queue: :fork_drop) do |_connection, channel, queue|
      publish_confirmed(channel, queue)
      assert_size 1, queue.name, amqp_url: AMQP_URL, reuse_connection: true

      parent_session = HireFire::Macro::Bunny.instance_variable_get(:@reused_connection)
      refute_nil parent_session
      assert parent_session.open?

      read_io, write_io = IO.pipe
      pid = Process.fork do
        read_io.close
        begin
          child_session = HireFire::Macro::Bunny.instance_variable_get(:@reused_connection)
          write_io.write(child_session.nil? ? "nil" : "present")
        ensure
          write_io.close
          exit!(0)
        end
      end
      write_io.close
      status = read_io.read
      Process.wait(pid)

      assert_equal "nil", status
      assert parent_session.open?, "parent session must stay open after the child drops it"

      Timeout.timeout(5) do
        assert_equal 1, HireFire::Macro::Bunny.job_queue_size(
          queue.name, amqp_url: AMQP_URL, reuse_connection: true
        )
      end
    end
  ensure
    old = HireFire::Macro::Bunny.instance_variable_get(:@reused_connection)
    HireFire::Macro::Bunny.send(:close_connection, old) if old
    HireFire::Macro::Bunny.reinit_after_fork
  end

  def test_reuse_connection_opens_once_across_calls
    HireFire::Macro::Bunny.reinit_after_fork
    fake = mock("bunny-reuse")
    fake.stubs(:open?).returns(true)
    fake.expects(:start).once
    channel = mock("channel")
    queue = mock("queue")
    queue.stubs(:message_count).returns(0)
    channel.stubs(:queue).returns(queue)
    channel.stubs(:close)
    fake.stubs(:create_channel).returns(channel)
    fake.stubs(:close)
    ::Bunny.expects(:new).once.returns(fake)

    2.times do
      HireFire::Macro::Bunny.job_queue_size(:default, amqp_url: AMQP_URL, reuse_connection: true)
    end
  ensure
    HireFire::Macro::Bunny.reinit_after_fork
  end

  def test_job_queue_size_reuses_provided_connection
    connection = ::Bunny.new(AMQP_URL).tap(&:start)

    with_connection(queue: :reuse_queue, durable: true) do |_conn, channel, queue|
      publish_confirmed(channel, queue)

      assert_size 1, :reuse_queue, connection: connection
      assert connection.open?, "provided connection must stay open for reuse"
      assert_size 1, :reuse_queue, connection: connection
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

    assert connection.open?, "a channel-level 404 must not close a reused connection"
  ensure
    connection&.close
  end

  def test_connection_close_failure_does_not_mask_body_error
    ::Bunny::Session.any_instance.stubs(:close).raises(::Bunny::Exception.new("close boom"))
    queue_name = "missing_#{rand(1_000_000)}"
    assert_raises ::Bunny::NotFound do
      HireFire::Macro::Bunny.job_queue_size(queue_name, amqp_url: AMQP_URL)
    end
  end

  def test_setup_channel_closes_connection_when_channel_creation_fails
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
    connection = mock("connection")
    connection.stubs(:create_channel).raises(::Bunny::Exception.new("channel boom"))
    connection.expects(:close).never

    assert_raises ::Bunny::Exception do
      HireFire::Macro::Bunny.job_queue_size(:default, connection: connection)
    end
  end

  def test_deprecated_queue_method
    with_connection(queue: :default_legacy, durable: true) do |_connection, default_channel, default|
      with_connection(queue: :mailer_legacy, durable: true) do |connection, mailer_channel, mailer|
        publish_confirmed(default_channel, default)
        publish_confirmed(mailer_channel, mailer)
        assert_size 1, :default_legacy, amqp_url: AMQP_URL
        seen = nil
        deadline = Time.now + 2
        while Time.now < deadline
          seen = HireFire::Macro::Bunny.queue(:default_legacy, :mailer_legacy, connection: connection)
          break if seen == 2
          sleep 0.02
        end
        assert_equal 2, seen
      end
    end
  end

  def test_deprecated_queue_method_requires_connection_or_amqp_url
    assert_raises ArgumentError do
      HireFire::Macro::Bunny.queue(:default)
    end
  end

  def test_acquire_connection_env_url_cascade
    keys = %w[AMQP_URL RABBITMQ_URL RABBITMQ_BIGWIG_URL CLOUDAMQP_URL]
    saved = keys.to_h { |k| [k, ENV[k]] }
    keys.each { |k| ENV.delete(k) }

    ENV["AMQP_URL"] = "amqp://amqp.example/vhost"
    ENV["RABBITMQ_URL"] = "amqp://rabbitmq.example/vhost"
    ENV["RABBITMQ_BIGWIG_URL"] = "amqp://bigwig.example/vhost"
    ENV["CLOUDAMQP_URL"] = "amqp://cloudamqp.example/vhost"
    expect_bunny_connection("amqp://amqp.example/vhost")

    keys.each { |k| ENV.delete(k) }
    ENV["RABBITMQ_URL"] = "amqp://rabbitmq.example/vhost"
    ENV["RABBITMQ_BIGWIG_URL"] = "amqp://bigwig.example/vhost"
    ENV["CLOUDAMQP_URL"] = "amqp://cloudamqp.example/vhost"
    expect_bunny_connection("amqp://rabbitmq.example/vhost")

    cascade = [
      ["AMQP_URL", "amqp://amqp-only.example/vhost"],
      ["RABBITMQ_URL", "amqp://rabbitmq-only.example/vhost"],
      ["RABBITMQ_BIGWIG_URL", "amqp://bigwig-only.example/vhost"],
      ["CLOUDAMQP_URL", "amqp://cloudamqp-only.example/vhost"]
    ]
    cascade.each do |set_key, url|
      keys.each { |k| ENV.delete(k) }
      ENV[set_key] = url
      expect_bunny_connection(url)
    end

    keys.each { |k| ENV.delete(k) }
    expect_bunny_connection("amqp://guest:guest@localhost:5672")
  ensure
    keys.each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
  end

  private

  def expect_bunny_connection(url)
    fake = mock("bunny-#{url}")
    fake.expects(:start).returns(true)
    ::Bunny.expects(:new).with(url).returns(fake)
    result = HireFire::Macro::Bunny.send(:acquire_connection, nil)
    assert_same fake, result
  end

  def publish_confirmed(channel, queue)
    channel.confirm_select
    queue.publish(TEST_MESSAGE)
    raise "publish was not confirmed" unless channel.wait_for_confirms
  end

  def assert_size(expected, *queues, **kwargs)
    deadline = Time.now + 2
    seen = nil
    while Time.now < deadline
      seen = HireFire::Macro::Bunny.job_queue_size(*queues, **kwargs)
      return if seen == expected
      sleep 0.02
    end
    assert_equal expected, seen
  end

  def with_connection(options = {})
    connection = ::Bunny.new(AMQP_URL)
    connection.start
    channel = connection.create_channel

    queue_name = options.fetch(:queue, "default").to_s
    durable = options.fetch(:durable, true)
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
