# frozen_string_literal: true

require "test_helper"
require "timeout"

class HireFireTest < Minitest::Test
  def test_version
    Gem::Version.new(HireFire::VERSION)
  end

  def test_version_accepts_rubygems_prerelease_form
    version = Gem::Version.new("2.0.0.rc1")
    assert version.prerelease?
    Gem::Version.new(HireFire::VERSION)
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

    HireFire.configure { |config| config.dyno(:web) }
  end

  def test_configure_token_assignment_starts_dispatcher
    HireFire::Dispatcher.any_instance.expects(:start).once

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

    config = HireFire.boot
    assert_equal config, HireFire.configuration
    assert_nil config.http
    assert config.job_queues.none?
  end

  def test_boot_without_token_does_not_start_dispatcher
    HireFire::Dispatcher.any_instance.expects(:start).never

    HireFire.boot
  end

  def test_a_sampler_configured_after_boot_is_sampled_once_the_lease_is_granted
    ENV["HIREFIRE_TOKEN"] = "test-token-value"
    HireFire::Plan.stubs(:any_allowlisted_job_queue_library_loaded?).returns(false)
    bodies = []
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return do |request|
      bodies << JSON.parse(request.body)
      {status: 200}
    end
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "true",
        "HireFire-Sample-Frequency" => "15"
      }, body: {version: 1, job_queues: [{name: "worker", strategy: "jql", adapter: nil, queues: [], options: {}}]}.to_json)
    original_tick = HireFire::Dispatcher::TICK
    HireFire::Dispatcher.send(:remove_const, :TICK)
    HireFire::Dispatcher.const_set(:TICK, 0.01)

    HireFire.boot
    assert HireFire.configuration.dispatcher.running?
    HireFire.configure do |config|
      config.dyno(:worker) { 42 }
    end

    400.times do
      break if bodies.any?

      sleep(0.005)
    end
    assert_equal 42, bodies.dig(0, 0, "metrics", "jql")&.values&.first
    assert_equal "worker", bodies.dig(0, 0, "name")
  ensure
    HireFire::Dispatcher.send(:remove_const, :TICK)
    HireFire::Dispatcher.const_set(:TICK, original_tick)
  end

  def test_configure_does_not_start_the_dispatcher_in_a_one_off_dyno
    ENV["HIREFIRE_TOKEN"] = "test-token-value"
    HireFire::Dispatcher.any_instance.expects(:start).never

    %w[run.4821 release.7310 RUN.1].each do |dyno|
      ENV["DYNO"] = dyno
      HireFire.configure { |config| config.dyno(dyno) { 1 } }
      HireFire.boot
    end
  end

  def test_configure_does_not_start_in_a_one_off_dyno_that_carries_an_app_wide_service_name
    ENV["HIREFIRE_TOKEN"] = "test-token-value"
    ENV["HIREFIRE_SERVICE_NAME"] = "web"
    ENV["DYNO"] = "run.4821"
    HireFire::Dispatcher.any_instance.expects(:start).never

    HireFire.boot
  end

  def test_configure_starts_the_dispatcher_in_every_other_dyno
    ENV["HIREFIRE_TOKEN"] = "test-token-value"
    HireFire::Dispatcher.any_instance.expects(:start).times(4)

    %w[web.1 worker.3 scheduler.5512 runner.1].each do |dyno|
      ENV["DYNO"] = dyno
      HireFire.boot
    end
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

    HireFire.after_fork_in_parent(Process.pid)

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

    HireFire.after_fork_in_parent(Process.pid)
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

    HireFire.after_fork_in_parent(Process.pid)

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

  def test_a_web_process_that_forks_a_helper_reports_again_once_the_helper_is_gone
    skip "Process.fork unavailable" unless Process.respond_to?(:fork)
    boot_web_process

    with_tick(0.01) do
      pid = Process.fork { exit!(0) }
      Process.wait(pid)

      wait_until { HireFire.configuration.dispatcher.running? }
      wait_until { Thread.list.none? { |thread| thread.name == "hirefire-handoff" } }
    end
  end

  def test_a_web_process_that_handed_over_stays_stopped_while_its_child_lives
    skip "Process.fork unavailable" unless Process.respond_to?(:fork)
    boot_web_process

    with_tick(0.01) do
      hold, release = IO.pipe
      pids = Array.new(2) do
        Process.fork do
          release.close
          hold.read
          exit!(0)
        end
      end
      hold.close
      sleep(0.1)
      refute HireFire.configuration.dispatcher.running?

      release.close
      pids.each { |pid| Process.wait(pid) }
      wait_until { HireFire.configuration.dispatcher.running? }
    end
  end

  def test_a_web_process_that_has_served_a_request_keeps_reporting_when_it_forks_and_its_child_reports_nothing
    skip "Process.fork unavailable" unless Process.respond_to?(:fork)
    boot_web_process
    HireFire::Middleware.new(->(_env) { [200, {}, []] }).call("HTTP_X_REQUEST_START" => "t=#{Time.now.to_f}")

    read_io, write_io = IO.pipe
    pid = Process.fork do
      read_io.close
      write_io.write(HireFire.configuration.dispatcher.running? ? "running" : "stopped")
      write_io.close
      exit!(0)
    end
    write_io.close
    child = read_io.read
    Process.wait(pid)

    assert_equal "stopped", child
    assert HireFire.configuration.dispatcher.running?
    assert_empty Thread.list.select { |thread| thread.name == "hirefire-handoff" }
  end

  def test_a_reset_after_a_handover_is_not_undone_when_the_child_is_gone
    skip "Process.fork unavailable" unless Process.respond_to?(:fork)
    boot_web_process

    with_tick(0.01) do
      pid = Process.fork { exit!(0) }
      HireFire.reset
      Process.wait(pid)

      wait_until { Thread.list.none? { |thread| thread.name == "hirefire-handoff" } }
      refute HireFire.configuration.dispatcher.running?
    end
  end

  def test_a_parent_that_started_again_on_its_own_is_left_alone
    skip "Process.fork unavailable" unless Process.respond_to?(:fork)
    boot_web_process

    with_tick(0.01) do
      hold, release = IO.pipe
      pid = Process.fork do
        release.close
        hold.read
        exit!(0)
      end
      hold.close
      refute HireFire.configuration.dispatcher.running?
      HireFire::Dispatcher.any_instance.expects(:start).once.returns(true)
      HireFire::Dispatcher.any_instance.stubs(:running?).returns(true)

      HireFire.configuration.dispatcher.start
      wait_until { Thread.list.none? { |thread| thread.name == "hirefire-handoff" } }
    ensure
      release&.close
      Process.wait(pid) if pid
    end
  end

  def test_a_handover_applies_only_to_a_platform_web_process_that_has_not_served_a_request
    ENV["DYNO"] = "worker.1"
    refute HireFire.configuration.prefork_web_handoff?

    ENV["DYNO"] = "web.1"
    assert HireFire.configuration.prefork_web_handoff?

    HireFire.configuration.mark_http_active!
    refute HireFire.configuration.prefork_web_handoff?

    ENV["DYNO"] = nil
    refute HireFire.configuration.prefork_web_handoff?
  end

  private

  def boot_web_process
    ENV["HIREFIRE_TOKEN"] = "test-token-value"
    ENV["DYNO"] = "web.1"
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {"HireFire-Lease-Granted" => "false"})
    HireFire.boot
    assert HireFire.configuration.dispatcher.running?
  end

  def with_tick(seconds)
    original = HireFire::Dispatcher::TICK
    HireFire::Dispatcher.send(:remove_const, :TICK)
    HireFire::Dispatcher.const_set(:TICK, seconds)
    yield
  ensure
    HireFire::Dispatcher.send(:remove_const, :TICK)
    HireFire::Dispatcher.const_set(:TICK, original)
  end

  def wait_until(seconds = 3)
    (seconds / 0.005).to_i.times do
      return if yield

      sleep(0.005)
    end
    flunk "the condition was not met within #{seconds} seconds"
  end
end
