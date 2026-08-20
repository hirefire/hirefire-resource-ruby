# frozen_string_literal: true

require "test_helper"
require "timeout"

class HireFireTest < Minitest::Test
  def test_version
    assert_match(/\A\d+\.\d+\.\d+\z/, HireFire::VERSION)
  end

  def test_configure_yields_configuration
    config = HireFire.configure { |config| config }
    assert_equal config, HireFire.configuration
  end

  def test_configure_yields_configuration_backwards_compatible
    config = HireFire::Resource.configure { |config| config }
    assert_equal config, HireFire::Resource.configuration
  end

  def test_configure_starts_dispatcher_when_token_is_set
    ENV["HIREFIRE_TOKEN"] = "test-token-value"
    HireFire::Dispatcher.any_instance.expects(:start).once
    HireFire::Dispatcher.any_instance.expects(:ensure_job_queue_loop).once

    HireFire.configure { |config| config.dyno(:web) }
  end

  def test_configure_token_assignment_starts_dispatcher_and_job_queue_loop
    HireFire::Dispatcher.any_instance.expects(:start).once
    HireFire::Dispatcher.any_instance.expects(:ensure_job_queue_loop).once

    HireFire.configure do |config|
      config.token = "inline-token-value"
      config.dyno(:web)
    end

    assert_equal "inline-token-value", HireFire.configuration.token
  end

  def test_configure_does_not_start_dispatcher_without_token
    HireFire::Dispatcher.any_instance.expects(:start).never

    HireFire.configure { |config| config.dyno(:web) }
  end

  def test_configure_does_not_start_dispatcher_with_empty_token
    ENV["HIREFIRE_TOKEN"] = ""
    HireFire::Dispatcher.any_instance.expects(:start).never

    HireFire.configure { |config| config.dyno(:web) }
  end

  def test_configure_does_not_start_dispatcher_when_token_is_forced_empty
    ENV["HIREFIRE_TOKEN"] = "from-env"
    HireFire::Dispatcher.any_instance.expects(:start).never

    HireFire.configure do |config|
      config.token = ""
      config.dyno(:web)
    end
  end

  def test_boot_is_configure_with_empty_block
    ENV["HIREFIRE_TOKEN"] = "test-token-value"
    HireFire::Dispatcher.any_instance.expects(:start).once
    HireFire::Dispatcher.any_instance.expects(:ensure_job_queue_loop).once

    config = HireFire.boot
    assert_equal config, HireFire.configuration
    assert_nil config.http
    assert config.job_queues.none?
  end

  def test_boot_without_token_does_not_start_dispatcher
    HireFire::Dispatcher.any_instance.expects(:start).never

    HireFire.boot
  end

  def test_additive_configure_after_boot_starts_worker_loop
    ENV["HIREFIRE_TOKEN"] = "test-token-value"
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      }, body: {version: 1, job_queues: [{name: "worker", strategy: "jql", adapter: nil, queues: [], options: {}}]}.to_json)

    HireFire.boot
    assert HireFire.configuration.dispatcher.running?

    HireFire.configure do |config|
      config.dyno(:worker) { 42 }
    end

    dispatcher = HireFire.configuration.dispatcher
    assert dispatcher.instance_variable_get(:@job_queue_thread)&.alive?

    dispatcher.send(:job_queue_tick)
    bodies = []
    stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .to_return do |request|
        bodies << JSON.parse(request.body)
        {status: 200}
      end
    dispatcher.send(:tick)

    assert(bodies[0]&.any? { |e| e["name"] == "worker" && e.dig("metrics", "jql") })
  end

  def test_reset_stops_dispatcher_and_replaces_configuration
    configuration = HireFire.configuration
    configuration.dispatcher.expects(:stop).once

    HireFire.reset

    refute_same configuration, HireFire.configuration
  end

  def test_after_fork_in_child_starts_when_token_present
    ENV["HIREFIRE_TOKEN"] = "test-token-value"
    ENV["DYNO"] = "web.1"
    HireFire::Dispatcher.any_instance.expects(:start).once
    HireFire::Dispatcher.any_instance.expects(:ensure_job_queue_loop).once

    HireFire.after_fork_in_child
  end

  def test_after_fork_in_child_web_without_token_does_not_start_or_abandon
    ENV.delete("HIREFIRE_TOKEN")
    ENV["DYNO"] = "web.1"
    HireFire.reset
    assert HireFire.configuration.prefork_web_handoff?
    HireFire::Dispatcher.any_instance.expects(:start).never
    HireFire::Dispatcher.any_instance.expects(:abandon_inherited_state!).never

    HireFire.after_fork_in_child
  ensure
    HireFire.reset
  end

  def test_after_fork_in_child_job_only_abandons_inherited_state
    ENV.delete("HIREFIRE_SERVICE_NAME")
    ENV.delete("RENDER_SERVICE_TYPE")
    ENV.delete("RENDER_SERVICE_NAME")
    ENV["HIREFIRE_TOKEN"] = "test-token-value"
    ENV["DYNO"] = "worker.1"
    HireFire.reset
    refute HireFire.configuration.prefork_web_handoff?
    HireFire::Dispatcher.any_instance.expects(:start).never
    HireFire::Dispatcher.any_instance.expects(:abandon_inherited_state!).once

    HireFire.after_fork_in_child
  ensure
    HireFire.reset
  end

  def test_after_fork_in_child_logs_start_failure
    ENV["HIREFIRE_TOKEN"] = "test-token-value"
    ENV["DYNO"] = "web.1"
    log = StringIO.new
    HireFire.configuration.logger = Logger.new(log)
    HireFire::Dispatcher.any_instance.stubs(:start).raises(RuntimeError, "spawn failed")

    HireFire.after_fork_in_child

    assert_includes log.string, "After-fork restart failed"
    assert_includes log.string, "spawn failed"
  end

  def test_after_fork_in_parent_stops_without_flush
    ENV["DYNO"] = "web.1"
    flush_args = []
    config = HireFire.configuration
    config.define_singleton_method(:stop_dispatcher) do |flush: true|
      flush_args << flush
    end

    HireFire.after_fork_in_parent

    assert_equal [false], flush_args
  ensure
    HireFire.instance_variable_set(:@configuration, nil)
  end

  def test_after_fork_in_parent_is_noop_for_job_only_process
    ENV.delete("HIREFIRE_SERVICE_NAME")
    ENV.delete("RENDER_SERVICE_TYPE")
    ENV.delete("RENDER_SERVICE_NAME")
    ENV["DYNO"] = "worker.1"
    HireFire.reset
    refute HireFire.configuration.prefork_web_handoff?

    called = false
    HireFire.configuration.define_singleton_method(:stop_dispatcher) do |**_|
      called = true
    end

    HireFire.after_fork_in_parent
    refute called, "job-only parent must not stop_dispatcher on fork"
  ensure
    HireFire.reset
  end

  def test_after_fork_in_parent_logs_stop_failure
    ENV["DYNO"] = "web.1"
    log = StringIO.new
    config = HireFire.configuration
    config.logger = Logger.new(log)
    config.define_singleton_method(:stop_dispatcher) do |flush: true|
      raise "stop failed"
    end

    HireFire.after_fork_in_parent

    assert_includes log.string, "After-fork parent stop failed"
    assert_includes log.string, "stop failed"
  ensure
    HireFire.instance_variable_set(:@configuration, nil)
  end

  def test_install_fork_hooks_is_idempotent
    HireFire.install_fork_hooks!
    HireFire.install_fork_hooks!
    assert HireFire.instance_variable_get(:@fork_hooks_installed)
  end

  def test_real_fork_restarts_child_and_stops_parent
    skip "Process.fork unavailable" unless Process.respond_to?(:fork)
    skip "Process._fork unavailable" unless Process.respond_to?(:_fork)

    ENV["HIREFIRE_TOKEN"] = "test-token-value"
    ENV["DYNO"] = "web.1"
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {"HireFire-Lease-Granted" => "false"})

    HireFire.boot
    assert HireFire.configuration.dispatcher.running?

    read_io, write_io = IO.pipe
    pid = Process.fork do
      read_io.close
      begin
        running = HireFire.configuration.dispatcher.running?
        write_io.write(running ? "running" : "stopped")
      ensure
        write_io.close
        exit!(0)
      end
    end
    write_io.close
    status = read_io.read
    Process.wait(pid)

    assert_equal "running", status
    refute HireFire.configuration.dispatcher.running?,
      "prefork parent must stop after fork so it does not claim empty web liveness"
  ensure
    HireFire.reset
  end

  def test_real_fork_keeps_job_only_parent_running
    skip "Process.fork unavailable" unless Process.respond_to?(:fork)
    skip "Process._fork unavailable" unless Process.respond_to?(:_fork)

    ENV["HIREFIRE_TOKEN"] = "test-token-value"
    ENV["DYNO"] = "worker.1"
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {"HireFire-Lease-Granted" => "false"})

    HireFire.boot
    assert HireFire.configuration.dispatcher.running?
    HireFire.configuration.buffer.sample("worker", "jql", 9)

    read_io, write_io = IO.pipe
    pid = Process.fork do
      read_io.close
      begin
        dispatcher = HireFire.configuration.dispatcher
        running = dispatcher.running?
        buffer_empty = HireFire.configuration.buffer.flush.empty?
        dispatcher.stop
        write_io.write([running ? "running" : "stopped", buffer_empty ? "empty" : "full"].join(","))
      ensure
        write_io.close
        exit!(0)
      end
    end
    write_io.close
    status = read_io.read
    Process.wait(pid)

    assert_equal "stopped,empty", status
    assert HireFire.configuration.dispatcher.running?,
      "fork-per-job parent must keep reporting after Process._fork"
  ensure
    HireFire.reset
  end

  def test_at_exit_stops_the_dispatcher
    skip "Process.fork unavailable" unless Process.respond_to?(:fork)

    ENV["HIREFIRE_TOKEN"] = "test-token-value"
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {"HireFire-Lease-Granted" => "false"})

    read_io, write_io = IO.pipe
    pid = Process.fork do
      read_io.close
      begin
        HireFire.reset
        HireFire.boot
        unless HireFire.configuration.dispatcher.running?
          write_io.write("not_started")
          write_io.close
          exit!(1)
        end

        config = HireFire.configuration
        config.define_singleton_method(:stop_dispatcher) do
          was_running = dispatcher.running?
          dispatcher.stop
          write_io.write(was_running ? "stopped_from_running" : "already_stopped")
          write_io.close
        end
      rescue => e
        write_io.write("error:#{e.class}:#{e.message}")
        write_io.close
        exit!(1)
      end
      exit(0)
    end
    write_io.close
    status = Timeout.timeout(5) { read_io.read }
    Process.wait(pid)

    assert_equal "stopped_from_running", status
  ensure
    HireFire.reset
  end
end
