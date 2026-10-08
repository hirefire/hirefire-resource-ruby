# frozen_string_literal: true

require "test_helper"
require "support/fake_server"
require "tmpdir"
require "rbconfig"

class HireFire::WireTest < Minitest::Test
  EPOCH = 1_767_225_600
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  GRANT_HEADERS = {
    "HireFire-Lease-Granted" => "true",
    "HireFire-Lease-TTL" => "5",
    "HireFire-Sample-Frequency" => "15"
  }.freeze
  WORKER_PLAN = JSON.generate("job_queues" => [{"name" => "worker", "strategy" => "jqs"}]).freeze
  GRANT = {status: 200, headers: GRANT_HEADERS, body: WORKER_PLAN}.freeze
  NO_GRANT = {status: 200, headers: {"HireFire-Lease-Granted" => "false", "HireFire-Lease-TTL" => "5"}}.freeze
  APP = ->(_env) { [200, {}, ["served"]] }
  CHUNKED_GRANT = {
    raw: "HTTP/1.1 200 OK\r\nHireFire-Lease-Granted: true\r\nTransfer-Encoding: chunked\r\n\r\n" +
      ("10000\r\n#{"x" * 65_536}\r\n" * 3) + "0\r\n\r\n"
  }.freeze

  def setup
    super
    WebMock.disable_net_connect!(allow_localhost: true)
    @log = StringIO.new
    @ingest = {status: 200}
    @lease = NO_GRANT
    @server = FakeServer.new { |request| (request.path == "/metrics/lease") ? @lease : @ingest }
    ENV["HIREFIRE_TOKEN"] = "wire-token"
    ENV["HIREFIRE_DATA_URL"] = @server.url
    HireFire.configuration.logger = Logger.new(@log)
  end

  def teardown
    HireFire.configuration.stop_dispatcher(flush: false)
    @server.stop
    WebMock.disable_net_connect!
    super
  end

  def test_the_first_request_of_a_web_process_carries_its_request_queue_time
    ENV["DYNO"] = "web.1"

    Timecop.freeze(Time.at(EPOCH)) do
      serve_request(queued_for: 0.025)
      request = wait_for_request("/metrics/ingest")

      assert_equal "POST", request.verb
      assert_equal "application/json", request.header("Content-Type")
      assert_equal "wire-token", request.header("HireFire-Token")
      assert_equal "Ruby-#{HireFire::VERSION}", request.header("HireFire-Agent")
      assert_equal %([{"name":"web","metrics":{"rqt":{"#{EPOCH}":[25.0,1]}}}]), request.body
    end
  end

  def test_an_idle_web_process_reports_the_current_second_as_empty
    ENV["DYNO"] = "web.1"

    Timecop.freeze(Time.at(EPOCH)) do
      HireFire.configure { |_| }

      assert_equal %([{"name":"web","metrics":{"rqt":{"#{EPOCH}":[]}}}]), wait_for_request("/metrics/ingest").body
    end
  end

  def test_a_process_with_a_sampler_asks_for_the_lease_and_reports_what_the_plan_names
    @lease = GRANT

    HireFire.configure { |config| config.dyno(:worker) { 42 } }
    lease = wait_for_request("/metrics/lease")
    ingest = wait_for_request("/metrics/ingest")

    assert_equal "POST", lease.verb
    assert_equal "", lease.body
    assert_equal "wire-token", lease.header("HireFire-Token")
    assert_equal "Ruby-#{HireFire::VERSION}", lease.header("HireFire-Agent")
    assert_match UUID, lease.header("HireFire-Process-ID")
    assert_match(/\A\[\{"name":"worker","metrics":\{"jqs":\{"\d{10}":42\}\}\}\]\z/, ingest.body)
  end

  def test_a_process_that_is_not_granted_the_lease_reports_no_job_metrics
    Timecop.freeze(Time.at(EPOCH)) do
      HireFire.configure { |config| config.dyno(:worker) { 42 } }
      wait_for_request("/metrics/lease")
      HireFire.configuration.stop_dispatcher

      assert_equal ["/metrics/lease"], @server.requests.map(&:path)
    end
  end

  def test_a_process_without_a_sampler_or_a_job_library_does_not_ask_for_the_lease
    ENV["DYNO"] = "web.1"

    Timecop.freeze(Time.at(EPOCH)) do
      HireFire.configure { |_| }
      wait_for_request("/metrics/ingest")
      HireFire.configuration.stop_dispatcher

      assert_equal ["/metrics/ingest"], @server.requests.map(&:path).uniq
    end
  end

  def test_a_process_without_a_token_opens_no_connection
    ENV["HIREFIRE_TOKEN"] = nil
    ENV["DYNO"] = "web.1"

    HireFire.configure { |config| config.dyno(:worker) { 42 } }
    serve_request(queued_for: 0.025)

    refute HireFire.configuration.dispatcher.running?
    assert_equal 0, @server.accepted
  end

  def test_stop_sends_what_is_still_buffered
    ENV["DYNO"] = "web.1"

    Timecop.freeze(Time.at(EPOCH)) do
      HireFire.configure { |_| }
      wait_for_request("/metrics/ingest")
      serve_request(queued_for: 0.04)
      HireFire.configuration.stop_dispatcher

      assert_equal %([{"name":"web","metrics":{"rqt":{"#{EPOCH}":[40.0,1]}}}]), @server.requests.last.body
    end
  end

  def test_the_child_of_a_forking_worker_opens_no_connection
    skip "Process.fork unavailable" unless Process.respond_to?(:fork)
    ENV["HIREFIRE_SERVICE_NAME"] = "worker"
    @lease = GRANT

    HireFire.configure { |config| config.dyno(:worker) { 42 } }
    wait_for_request("/metrics/ingest")
    accepted = @server.accepted
    pid = Process.fork do
      sleep(0.2)
      HireFire.configuration.stop_dispatcher
      exit!(0)
    end
    Process.wait(pid)

    assert_equal accepted, @server.accepted
    assert HireFire.configuration.dispatcher.running?
  end

  def test_a_failed_dispatch_is_logged_and_the_next_one_succeeds
    ENV["DYNO"] = "web.1"
    @ingest = {status: 500}

    HireFire.configure { |_| }
    wait_for_log("Dispatch error: HireFire::Errors::RequestError: Ingest request failed with 500 status.")
    @ingest = {status: 200}
    failed = @server.requests.size
    errors = @log.string.scan("Dispatch error").size
    wait_for("a dispatch after the failure") { @server.requests.size > failed }

    assert HireFire.configuration.dispatcher.running?
    HireFire.configuration.stop_dispatcher(flush: false)
    assert_equal errors, @log.string.scan("Dispatch error").size
  end

  INGEST_FAULTS = {
    "a_reset_connection" => [{then: :reset}, "Dispatch error: HireFire::Errors::RequestError: Network error ("],
    "a_closed_connection" => [{then: :close}, "Dispatch error: HireFire::Errors::RequestError: Network error ("],
    "a_reply_that_is_not_http" => [{raw: "\x00\xFFthis is not http\r\n\r\n".b, after: :close}, "Dispatch error: HireFire::Errors::RequestError: Network error (Net::HTTPBadResponse"],
    "a_redirect" => [{status: 302, headers: {"Location" => "/elsewhere"}}, "Dispatch error: HireFire::Errors::RequestError: Ingest request failed with 302 status."],
    "a_rate_limit" => [{status: 429, headers: {"Retry-After" => "30"}}, "Dispatch error: HireFire::Errors::RequestError: Ingest request failed with 429 status."],
    "an_unavailable_server" => [{status: 503}, "Dispatch error: HireFire::Errors::RequestError: Ingest request failed with 503 status."],
    "a_rejected_payload" => [{status: 413}, "Dropped metrics payload: 52 bytes server rejected (413)."]
  }.freeze

  INGEST_FAULTS.each do |name, (action, message)|
    define_method(:"test_#{name}_is_logged_and_leaves_the_host_and_the_dispatcher_running") do
      ENV["DYNO"] = "web.1"
      @ingest = action

      Timecop.freeze(Time.at(EPOCH)) do
        HireFire.configure { |_| }
        wait_for_log(message)

        assert_equal [200, {}, ["served"]], serve_request(queued_for: 0.025)
        assert HireFire.configuration.dispatcher.running?
      end
    end
  end

  def test_a_rejected_token_is_not_logged
    ENV["DYNO"] = "web.1"
    @ingest = {status: 401}

    Timecop.freeze(Time.at(EPOCH)) do
      HireFire.configure { |_| }
      wait_for_request("/metrics/ingest")
      HireFire.configuration.stop_dispatcher(flush: false)

      assert_equal ["Starting dispatcher.", "Dispatcher stopped."], log_messages
    end
  end

  def test_a_refused_connection_is_logged_and_leaves_the_dispatcher_running
    ENV["DYNO"] = "web.1"
    closed = TCPServer.new("127.0.0.1", 0)
    ENV["HIREFIRE_DATA_URL"] = "http://127.0.0.1:#{closed.addr[1]}"
    closed.close

    HireFire.configure { |_| }
    wait_for_log("Dispatch error: HireFire::Errors::RequestError: Network error (Errno::ECONNREFUSED")

    assert HireFire.configuration.dispatcher.running?
  end

  LEASE_FAULTS = {
    "a_grant_that_is_not_json" => ["{not json", "Lease grant body was not valid JSON. Plan ignored."],
    "a_grant_with_a_binary_body" => ["\xFF\xFE\x00\x01{".b, "Lease grant body was not valid JSON. Plan ignored."],
    "a_grant_that_is_not_an_object" => ["[1,2]", "Lease grant body was not a JSON object. Plan ignored."],
    "a_grant_without_a_list_of_entries" => [%({"job_queues":"worker"}), "Lease grant body job_queues was not an array. Plan ignored."],
    "a_grant_with_entries_of_the_wrong_shape" => [JSON.generate("job_queues" => [1, "two", nil, {"name" => 5}]), "Lease plan skipped 4 invalid job queue entries."],
    "a_grant_over_the_size_limit" => [JSON.generate("job_queues" => Array.new(4000) { |index| {"name" => "queue-#{index}", "strategy" => "jqs", "queues" => ["q#{index}"]} }), "HireFire::Errors::RequestError: Response body exceeded 131072 bytes (status 200)."],
    "a_chunked_grant_over_the_size_limit" => [:chunked, "HireFire::Errors::RequestError: Response body exceeded 131072 bytes (status 200)."]
  }.freeze

  LEASE_FAULTS.each do |name, (body, message)|
    define_method(:"test_#{name}_is_logged_and_samples_nothing") do
      @lease = (body == :chunked) ? CHUNKED_GRANT : {status: 200, headers: GRANT_HEADERS, body: body}

      Timecop.freeze(Time.at(EPOCH)) do
        HireFire.configure { |config| config.dyno(:worker) { 42 } }
        wait_for_log(message)
        HireFire.configuration.stop_dispatcher

        assert_equal ["/metrics/lease"], @server.requests.map(&:path)
      end
    end
  end

  def test_a_server_that_never_answers_fails_the_request_at_the_deadline_and_stop_returns_soon_after
    ENV["DYNO"] = "web.1"
    @ingest = {then: :stall}

    with_client_timeout(0.3) do
      HireFire.configure { |_| }
      wait_for_log("Dispatch error: HireFire::Errors::RequestError: Request timed out.")

      assert_operator seconds_to { HireFire.configuration.stop_dispatcher }, :<, 2
      assert_equal [200, {}, ["served"]], serve_request(queued_for: 0.025)
    end
  end

  def test_a_response_that_arrives_one_byte_at_a_time_fails_the_request_at_the_deadline
    ENV["DYNO"] = "web.1"
    @ingest = {status: 200, body: "x" * 40, drip: 0.1}

    with_client_timeout(0.3) do
      HireFire.configure { |_| }
      wait_for_log("Dispatch error: HireFire::Errors::RequestError: Request timed out.", seconds: 2)

      assert_operator seconds_to { HireFire.configuration.stop_dispatcher }, :<, 2
    end
  end

  def test_a_server_that_does_not_speak_tls_fails_the_request_at_the_deadline
    ENV["DYNO"] = "web.1"
    ENV["HIREFIRE_DATA_URL"] = "https://127.0.0.1:#{@server.port}"

    with_client_timeout(0.3) do
      HireFire.configure { |_| }
      wait_for_log("Dispatch error: HireFire::Errors::RequestError: Request timed out.", seconds: 2)

      assert HireFire.configuration.dispatcher.running?
      assert_operator seconds_to { HireFire.configuration.stop_dispatcher(flush: false) }, :<, 2
    end
  end

  def test_a_slow_answer_inside_the_deadline_is_a_success
    ENV["DYNO"] = "web.1"
    @ingest = {status: 200, delay: 0.2}

    with_client_timeout(1) do
      HireFire.configure { |_| }
      wait_for_request("/metrics/ingest")
      HireFire.configuration.stop_dispatcher(flush: false)

      assert_equal ["Starting dispatcher.", "Dispatcher stopped."], log_messages
    end
  end

  def test_a_failed_lease_request_is_logged_and_leaves_the_dispatcher_running
    @lease = {status: 500}

    HireFire.configure { |config| config.dyno(:worker) { 42 } }
    wait_for_log("Lease request error: HireFire::Errors::RequestError: Lease request failed with 500 status.")

    assert HireFire.configuration.dispatcher.running?
  end

  def test_a_process_that_daemonizes_keeps_reporting
    skip "Process.fork unavailable" unless Process.respond_to?(:fork)
    Dir.mktmpdir("hirefire-daemon") do |dir|
      go = File.join(dir, "go")
      pid_file = File.join(dir, "pid")
      script = <<~RUBY
        require "hirefire-resource"
        require "logger"
        HireFire.configure { |config| config.logger = Logger.new(File::NULL) }
        sleep(0.01) until File.exist?(ARGV[0])
        Process.daemon(true, true)
        File.write(ARGV[1], Process.pid.to_s)
        sleep(10)
      RUBY
      env = {"HIREFIRE_TOKEN" => "wire-token", "HIREFIRE_DATA_URL" => @server.url, "DYNO" => "web.1", "RUBYOPT" => nil}
      starter = Process.spawn(env, RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", script, go, pid_file)

      wait_for_request("/metrics/ingest")
      before = @server.requests.size
      File.write(go, "")
      Process.wait(starter)
      wait_for("the pid of the daemon") { File.exist?(pid_file) && !File.read(pid_file).empty? }

      wait_for("a request from the daemon") { @server.accepted >= 2 && @server.requests.size > before }
      assert_operator @server.accepted, :>=, 2
    ensure
      Process.kill("KILL", File.read(pid_file).to_i) if pid_file && File.exist?(pid_file)
    end
  end

  private

  def serve_request(queued_for:)
    HireFire::Middleware.new(APP).call("HTTP_X_REQUEST_START" => "t=#{Time.now.to_f - queued_for}")
  end

  def with_client_timeout(seconds)
    original = HireFire::Client::TIMEOUT
    HireFire::Client.send(:remove_const, :TIMEOUT)
    HireFire::Client.const_set(:TIMEOUT, seconds)
    yield
  ensure
    HireFire::Client.send(:remove_const, :TIMEOUT)
    HireFire::Client.const_set(:TIMEOUT, original)
  end

  def seconds_to
    started = Time.now
    yield
    Time.now - started
  end

  def wait_for(what, seconds: 5)
    (seconds / 0.005).to_i.times do
      found = yield
      return found if found

      sleep(0.005)
    end
    flunk "#{what} did not happen within #{seconds} seconds. Log:\n#{@log.string}"
  end

  def wait_for_request(path)
    wait_for("a request to #{path}") { @server.requests.find { |request| request.path == path } }
  end

  def wait_for_log(message, seconds: 5)
    wait_for("the log line #{message.inspect}", seconds: seconds) { @log.string.include?(message) }
  end

  def log_messages
    @log.string.lines.map { |line| line[/\[HireFire\] (.*)$/, 1] }
  end
end
