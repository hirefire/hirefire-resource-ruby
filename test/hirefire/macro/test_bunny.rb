# frozen_string_literal: true

require "test_helper"
require "timeout"
require "socket"

ENV["AMQP_URL"] ||= "amqp://guest:guest@127.0.0.1:#{ENV.fetch("RABBITMQ_PORT", 5672)}"

class HireFire::Macro::BunnyTest < Minitest::Test
  AMQP_URL = ENV.fetch("AMQP_URL")
  TEST_MESSAGE = "Test Message"

  def test_library_loaded_is_true_when_bunny_gem_is_loaded
    assert HireFire::Macro::Bunny.library_loaded?
    assert HireFire::Plan.any_library_loaded?
  end

  def test_queues_required
    assert HireFire::Macro::Bunny.queues_required?
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
    error = assert_raises HireFire::Errors::JobQueueLatencyUnsupportedError do
      HireFire::Macro::Bunny.job_queue_latency(:default)
    end
    assert_equal "HireFire::Macro::Bunny currently does not support job queue latency measurements.", error.message
  end

  def test_job_queue_size_empty_ready_queue_is_zero
    with_connection(queue: :empty_ready) do |_connection, _channel, queue|
      size = HireFire::Macro::Bunny.job_queue_size(queue.name, amqp_url: AMQP_URL)
      assert_integer_count size
      assert_equal 0, size
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

  def test_job_queue_size_counts_a_missing_queue_as_zero
    size = HireFire::Macro::Bunny.job_queue_size(missing_queue_name, amqp_url: AMQP_URL)
    assert_integer_count size
    assert_equal 0, size
  end

  def test_job_queue_size_counts_existing_queues_around_a_missing_one
    with_connection(queue: :before_missing) do |_connection, channel, before|
      with_connection(queue: :after_missing) do |_connection, after_channel, after|
        publish_confirmed(channel, before)
        publish_confirmed(after_channel, after)
        assert_size 2, :before_missing, missing_queue_name, :after_missing, amqp_url: AMQP_URL
      end
    end
  end

  def test_missing_queue_reopens_the_channel_for_the_next_queue
    first = mock("first-channel")
    second = mock("second-channel")
    existing = mock("queue")
    existing.stubs(:message_count).returns(3)
    first.expects(:queue).with("missing", passive: true).raises(::Bunny::NotFound.new("NOT_FOUND", first, nil))
    first.expects(:close).never
    second.expects(:queue).with("default", passive: true).returns(existing)
    second.expects(:close).once
    connection = mock("connection")
    connection.expects(:create_channel).twice.returns(first, second)
    connection.expects(:close).never

    assert_equal 3, HireFire::Macro::Bunny.job_queue_size(:missing, :default, connection: connection)
  end

  def test_missing_queue_as_the_last_queue_opens_no_second_channel
    channel = mock("channel")
    existing = mock("queue")
    existing.stubs(:message_count).returns(3)
    channel.expects(:queue).with("default", passive: true).returns(existing)
    channel.expects(:queue).with("missing", passive: true).raises(::Bunny::NotFound.new("NOT_FOUND", channel, nil))
    channel.expects(:close).never
    connection = mock("connection")
    connection.expects(:create_channel).once.returns(channel)

    assert_equal 3, HireFire::Macro::Bunny.job_queue_size(:default, :missing, connection: connection)
  end

  def test_missing_queue_warning_is_logged_once_per_queue
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)
    first = missing_queue_name
    second = missing_queue_name

    2.times { HireFire::Macro::Bunny.job_queue_size(first, amqp_url: AMQP_URL) }
    HireFire::Macro::Bunny.job_queue_size(first, second, amqp_url: AMQP_URL)

    assert_equal 1, log.string.scan(first.inspect).size
    assert_equal 1, log.string.scan(second.inspect).size
    assert_includes log.string, "does not exist. It counts as 0 messages."
  end

  def test_plan_execute_records_zero_for_a_missing_queue
    HireFire.configure { |c| c.logger = Logger.new(File::NULL) }
    buffer = HireFire.configuration.buffer
    buffer.flush

    sample_plan(
      "name" => "worker",
      "adapter" => "bunny",
      "strategy" => "jqs",
      "queues" => [missing_queue_name],
      "options" => {}
    )

    reused = HireFire::Macro::Bunny.instance_variable_get(:@reused_connection)
    assert reused&.open?, "a missing queue must not drop the reused connection"
    assert_equal 0, buffer.flush.dig("worker", "jqs")&.values&.last
  ensure
    old = HireFire::Macro::Bunny.instance_variable_get(:@reused_connection)
    HireFire::Macro::Bunny.send(:close_connection, old) if old
    HireFire::Macro::Bunny.reinit_after_fork
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

  def test_a_fork_reset_works_while_another_thread_holds_the_connection_lock
    holder = Thread.new { HireFire::Macro::Bunny.instance_variable_get(:@connection_mutex).synchronize { sleep } }
    sleep(0.01) until holder.status == "sleep"

    HireFire::Macro::Bunny.reinit_after_fork

    with_connection(queue: :fork_lock) do |_connection, channel, queue|
      publish_confirmed(channel, queue)
      Timeout.timeout(5) { assert_size 1, queue.name, amqp_url: AMQP_URL, reuse_connection: true }
    end
  ensure
    holder&.kill
    HireFire::Macro::Bunny.release
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

  def test_a_sample_without_reuse_closes_the_connection_it_opened
    with_connection(queue: :owned_close) do |_connection, channel, queue|
      publish_confirmed(channel, queue)
      before = open_sessions

      2.times { assert_size 1, queue.name, amqp_url: AMQP_URL }

      assert_equal before, open_sessions
    end
  end

  def test_a_given_connection_is_used_even_when_reuse_is_asked_for
    given = ::Bunny.new(AMQP_URL).tap(&:start)

    with_connection(queue: :given_reuse) do |_connection, channel, queue|
      publish_confirmed(channel, queue)
      before = open_sessions

      assert_size 1, queue.name, connection: given, reuse_connection: true, amqp_url: "amqp://guest:guest@127.0.0.1:1"

      assert_equal before, open_sessions
      assert given.open?
    end
  ensure
    given&.close
    HireFire::Macro::Bunny.reinit_after_fork
  end

  def test_a_failed_sample_on_the_reused_connection_closes_it_and_the_next_sample_opens_another
    with_connection(queue: :reuse_fail) do |_connection, channel, queue|
      publish_confirmed(channel, queue)
      before = open_sessions
      assert_size 1, queue.name, amqp_url: AMQP_URL, reuse_connection: true
      assert_equal before + 1, open_sessions

      ::Bunny::Channel.any_instance.stubs(:queue).raises(::Bunny::AccessRefused.new("ACCESS_REFUSED", nil, nil))
      assert_raises(::Bunny::AccessRefused) do
        HireFire::Macro::Bunny.job_queue_size(queue.name, amqp_url: AMQP_URL, reuse_connection: true)
      end
      ::Bunny::Channel.any_instance.unstub(:queue)

      assert_equal before, open_sessions
      assert_size 1, queue.name, amqp_url: AMQP_URL, reuse_connection: true
      assert_equal before + 1, open_sessions
    end
  ensure
    HireFire::Macro::Bunny.release
  end

  def test_a_failed_sample_on_a_given_connection_leaves_the_reused_connection_open
    given = ::Bunny.new(AMQP_URL).tap(&:start)

    with_connection(queue: :reuse_kept) do |_connection, channel, queue|
      publish_confirmed(channel, queue)
      assert_size 1, queue.name, amqp_url: AMQP_URL, reuse_connection: true
      before = open_sessions

      ::Bunny::Channel.any_instance.stubs(:queue).raises(::Bunny::AccessRefused.new("ACCESS_REFUSED", nil, nil))
      assert_raises(::Bunny::AccessRefused) { HireFire::Macro::Bunny.job_queue_size(queue.name, connection: given) }
      assert_raises(::Bunny::AccessRefused) { HireFire::Macro::Bunny.job_queue_size(queue.name, amqp_url: AMQP_URL) }
      ::Bunny::Channel.any_instance.unstub(:queue)

      assert_equal before, open_sessions
    end
  ensure
    given&.close
    HireFire::Macro::Bunny.release
  end

  def test_a_connection_that_fails_to_start_is_closed_and_its_error_is_raised
    session = mock("session")
    session.stubs(:start).raises(::Bunny::Exception.new("start boom"))
    session.expects(:close).once
    ::Bunny.stubs(:new).returns(session)

    error = assert_raises(::Bunny::Exception) { HireFire::Macro::Bunny.job_queue_size(:default, amqp_url: AMQP_URL) }

    assert_equal "start boom", error.message
  end

  def test_the_reused_connection_is_replaced_when_the_url_changes_and_the_old_one_is_closed
    first = reusable_session
    second = reusable_session
    ::Bunny.expects(:new).with("amqp://one.example", anything).once.returns(first)
    ::Bunny.expects(:new).with("amqp://two.example", anything).once.returns(second)
    first.expects(:close).once

    2.times { HireFire::Macro::Bunny.job_queue_size(:default, amqp_url: "amqp://one.example", reuse_connection: true) }
    2.times { HireFire::Macro::Bunny.job_queue_size(:default, amqp_url: "amqp://two.example", reuse_connection: true) }
  ensure
    second&.stubs(:close)
    HireFire::Macro::Bunny.reinit_after_fork
  end

  def test_a_reused_connection_that_is_no_longer_open_is_closed_and_replaced
    first = reusable_session(open: false)
    second = reusable_session
    ::Bunny.expects(:new).twice.returns(first, second)
    first.expects(:close).once

    2.times { HireFire::Macro::Bunny.job_queue_size(:default, amqp_url: AMQP_URL, reuse_connection: true) }
  ensure
    second&.stubs(:close)
    HireFire::Macro::Bunny.reinit_after_fork
  end

  def test_a_reused_connection_whose_state_cannot_be_read_is_replaced
    first = reusable_session
    first.stubs(:open?).raises(::Bunny::Exception.new("state boom"))
    second = reusable_session
    ::Bunny.expects(:new).twice.returns(first, second)
    first.expects(:close).once

    2.times { HireFire::Macro::Bunny.job_queue_size(:default, amqp_url: AMQP_URL, reuse_connection: true) }
  ensure
    second&.stubs(:close)
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

  def test_provided_connection_survives_a_missing_queue
    connection = ::Bunny.new(AMQP_URL).tap(&:start)

    2.times do
      assert_equal 0, HireFire::Macro::Bunny.job_queue_size(missing_queue_name, connection: connection)
    end

    assert connection.open?, "a channel-level 404 must not close a provided connection"
  ensure
    connection&.close
  end

  def test_connection_close_failure_does_not_mask_body_error
    ::Bunny::Session.any_instance.stubs(:close).raises(::Bunny::Exception.new("close boom"))
    ::Bunny::Channel.any_instance.stubs(:queue).raises(::Bunny::AccessRefused.new("ACCESS_REFUSED", nil, nil))

    assert_raises ::Bunny::AccessRefused do
      HireFire::Macro::Bunny.job_queue_size(:default, amqp_url: AMQP_URL)
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
        assert_eventually(2) do
          HireFire::Macro::Bunny.queue(:default_legacy, :mailer_legacy, connection: connection)
        end
        assert_eventually(2) do
          HireFire::Macro::Bunny.queue([:default_legacy, ["mailer_legacy"]], {connection: connection})
        end
      end
    end
  end

  def test_deprecated_queue_method_falls_back_to_the_environment_url
    with_connection(queue: :environment_legacy) do |_connection, channel, queue|
      publish_confirmed(channel, queue)
      assert_eventually(1) { HireFire::Macro::Bunny.queue(:environment_legacy) }
    end
  end

  def test_deprecated_queue_method_accepts_and_drops_durable_and_max_priority
    with_connection(queue: :priority_legacy, max_priority: 10) do |_connection, channel, queue|
      publish_confirmed(channel, queue)
      assert_eventually(1) { HireFire::Macro::Bunny.queue(:priority_legacy, amqp_url: AMQP_URL) }
      assert_equal 1, HireFire::Macro::Bunny.queue(:priority_legacy, amqp_url: AMQP_URL, durable: true, "x-max-priority": 10)
      assert_equal 1, HireFire::Macro::Bunny.queue(:priority_legacy, amqp_url: AMQP_URL, durable: false, "x-max-priority": 5)
      assert_equal 1, HireFire::Macro::Bunny.job_queue_size(:priority_legacy, amqp_url: AMQP_URL)
    end
  end

  def test_deprecated_queue_passes_on_only_the_connection_options
    connection = Object.new
    HireFire::Macro::Bunny.expects(:job_queue_size)
      .with(:default, "mailer", connection: connection, amqp_url: AMQP_URL)
      .returns(7)

    assert_equal 7, HireFire::Macro::Bunny.queue(
      [:default, ["mailer"]],
      connection: connection,
      amqp_url: AMQP_URL,
      durable: false,
      "x-max-priority": 10,
      reuse_connection: true,
      bogus: 1
    )
  end

  def test_deprecated_queue_method_does_not_create_a_missing_queue
    name = missing_queue_name
    assert_equal 0, HireFire::Macro::Bunny.queue(name, amqp_url: AMQP_URL, durable: true)

    connection = ::Bunny.new(AMQP_URL).tap(&:start)
    refute connection.queue_exists?(name)
  ensure
    connection&.close
  end

  def test_deprecated_queue_method_without_queue_names_raises
    assert_raises HireFire::Errors::MissingQueueError do
      HireFire::Macro::Bunny.queue(amqp_url: AMQP_URL)
    end
  end

  def test_owned_connection_times_out_on_accepting_blackhole
    with_fast_sample_timeouts do
      url, stop_blackhole = start_amqp_blackhole
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raised = nil
      begin
        HireFire::Macro::Bunny.job_queue_size(:default, amqp_url: url)
      rescue
        raised = $!
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert elapsed < 8, "sample parked for #{elapsed}s (#{raised.inspect})"
      refute_nil raised, "blackhole handshake must fail the sample"
      assert_nil HireFire::Macro::Bunny.instance_variable_get(:@reused_connection)
    ensure
      stop_blackhole&.call
      HireFire::Macro::Bunny.reinit_after_fork
    end
  end

  def test_reused_connection_times_out_on_accepting_blackhole_and_drops_session
    with_fast_sample_timeouts do
      url, stop_blackhole = start_amqp_blackhole
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raised = nil
      begin
        HireFire::Macro::Bunny.job_queue_size(:default, amqp_url: url, reuse_connection: true)
      rescue
        raised = $!
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert elapsed < 8, "sample parked for #{elapsed}s (#{raised.inspect})"
      refute_nil raised, "blackhole handshake must fail the sample"
      assert_nil HireFire::Macro::Bunny.instance_variable_get(:@reused_connection)
    ensure
      stop_blackhole&.call
      HireFire::Macro::Bunny.reinit_after_fork
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
    ENV["AMQP_URL"] = ""
    ENV["RABBITMQ_URL"] = "  "
    ENV["CLOUDAMQP_URL"] = " amqp://cloudamqp.example/vhost "
    expect_bunny_connection("amqp://cloudamqp.example/vhost")

    keys.each { |k| ENV.delete(k) }
    expect_bunny_connection("amqp://guest:guest@localhost:5672")
  ensure
    keys.each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
  end

  def test_the_connection_that_plan_samples_reuse_closes_when_the_library_is_reset
    with_connection(queue: :reuse_reset) do |_connection, _channel, queue|
      before = open_sessions
      HireFire::Plan.around_job_queue_sample(HireFire.configuration.logger) do
        HireFire::Macro::Bunny.job_queue_size(queue.name, **HireFire::Macro::Bunny.plan_connection_options)
      end
      assert_equal before + 1, open_sessions

      HireFire.configuration.stop_dispatcher
      HireFire.reset

      assert_equal before, open_sessions
    end
  end

  def test_the_connection_that_plan_samples_reuse_closes_when_the_process_loses_the_lease
    with_connection(queue: :reuse_lease) do |_connection, _channel, queue|
      ENV["HIREFIRE_TOKEN"] = "test-token-value"
      granted = true
      stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
      stub_request(:post, "https://data.hirefire.io/metrics/lease").to_return do |_request|
        {status: 200, headers: {"HireFire-Lease-Granted" => granted.to_s, "HireFire-Lease-TTL" => "5"},
         body: {job_queues: [{"name" => "worker", "strategy" => "jqs", "adapter" => "bunny", "queues" => [queue.name]}]}.to_json}
      end
      before = open_sessions
      original_tick = HireFire::Dispatcher::TICK
      HireFire::Dispatcher.send(:remove_const, :TICK)
      HireFire::Dispatcher.const_set(:TICK, 0.01)

      HireFire.configuration.dispatcher.start
      wait_for { open_sessions == before + 1 }
      granted = false
      Timecop.travel(Time.now + 6)
      wait_for { open_sessions == before }

      assert HireFire.configuration.dispatcher.running?
    ensure
      Timecop.return
      HireFire.configuration.stop_dispatcher(flush: false)
      HireFire::Dispatcher.send(:remove_const, :TICK)
      HireFire::Dispatcher.const_set(:TICK, original_tick)
    end
  end

  def test_the_connection_that_plan_samples_reuse_closes_when_the_dispatcher_stops
    with_connection(queue: :reuse_stop) do |_connection, _channel, queue|
      ENV["HIREFIRE_TOKEN"] = "test-token-value"
      stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
      stub_request(:post, "https://data.hirefire.io/metrics/lease").to_return(
        status: 200, headers: {"HireFire-Lease-Granted" => "true", "HireFire-Lease-TTL" => "5"},
        body: {job_queues: [{"name" => "worker", "strategy" => "jqs", "adapter" => "bunny", "queues" => [queue.name]}]}.to_json
      )
      before = open_sessions

      HireFire.configuration.dispatcher.start
      wait_for { open_sessions == before + 1 }
      HireFire.configuration.dispatcher.stop

      wait_for { open_sessions == before }
    end
  end

  def test_release_without_a_reused_connection_does_nothing
    HireFire::Macro::Bunny.release
    HireFire::Macro::Bunny.release
  end

  private

  def reusable_session(open: true)
    queue = stub(message_count: 0)
    channel = stub(queue: queue, close: nil)
    session = mock("session")
    session.stubs(:start)
    session.stubs(:open?).returns(open)
    session.stubs(:create_channel).returns(channel)
    session
  end

  def missing_queue_name
    "missing_#{rand(1_000_000_000)}"
  end

  def expect_bunny_connection(url)
    fake = mock("bunny-#{url}")
    fake.expects(:start).returns(true)
    ::Bunny.expects(:new).with(
      url,
      HireFire::Macro::Bunny::SAMPLE_CONNECTION_OPTIONS
    ).returns(fake)
    result = HireFire::Macro::Bunny.send(:acquire_connection, nil)
    assert_same fake, result
  end

  def with_fast_sample_timeouts
    options = HireFire::Macro::Bunny::SAMPLE_CONNECTION_OPTIONS
    fast = options.merge(
      connection_timeout: 1,
      continuation_timeout: 300,
      read_timeout: 0.3,
      write_timeout: 0.3
    )
    HireFire::Macro::Bunny.send(:remove_const, :SAMPLE_CONNECTION_OPTIONS)
    HireFire::Macro::Bunny.const_set(:SAMPLE_CONNECTION_OPTIONS, fast)
    yield
  ensure
    HireFire::Macro::Bunny.send(:remove_const, :SAMPLE_CONNECTION_OPTIONS)
    HireFire::Macro::Bunny.const_set(:SAMPLE_CONNECTION_OPTIONS, options)
  end

  def start_amqp_blackhole
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    stop = false
    thread = Thread.new do
      until stop
        begin
          client = server.accept
          Thread.new { sleep 30 } unless client.nil?
        rescue
          break
        end
      end
    end
    url = "amqp://guest:guest@127.0.0.1:#{port}"
    stopper = lambda do
      stop = true
      begin
        server.close
      rescue
        nil
      end
      thread.kill
    end
    [url, stopper]
  end

  def publish_confirmed(channel, queue)
    channel.confirm_select
    queue.publish(TEST_MESSAGE)
    raise "publish was not confirmed" unless channel.wait_for_confirms
  end

  def assert_size(expected, *queues, **kwargs)
    assert_eventually(expected) do
      HireFire::Macro::Bunny.job_queue_size(*queues, **kwargs).tap { |seen| assert_integer_count seen }
    end
  end

  def assert_eventually(expected)
    deadline = Time.now + 2
    seen = nil
    while Time.now < deadline
      seen = yield
      return if seen == expected
      sleep 0.02
    end
    assert_equal expected, seen
  end

  def open_sessions
    ObjectSpace.each_object(::Bunny::Session).count { |session| session.instance_variable_get(:@status_mutex) && session.open? }
  end

  def wait_for(seconds = 3)
    (seconds / 0.005).to_i.times do
      return if yield

      sleep(0.005)
    end
    flunk "the condition was not met within #{seconds} seconds"
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
