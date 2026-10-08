# frozen_string_literal: true

require "test_helper"

class HireFire::ClientTest < Minitest::Test
  def client
    @client ||= HireFire::Client.new
  end

  def log
    @log ||= StringIO.new
  end

  def setup
    super
    ENV["HIREFIRE_TOKEN"] = "test-token-value"
    WebMock.reset_executed_requests!
    HireFire.configuration.logger = Logger.new(log)
  end

  def test_client_source_does_not_require_json
    path = File.expand_path("../../lib/hirefire/client.rb", __dir__)
    refute_match(/require ["']json["']/, File.read(path))
  end

  def test_submit_samples_sends_payload
    request = stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .with(
        body: '[{"name":"web","metrics":{"1000":[]}}]',
        headers: {
          "Content-Type" => "application/json",
          "HireFire-Token" => "test-token-value",
          "HireFire-Agent" => "Ruby-#{HireFire::VERSION}"
        }
      )
      .to_return(status: 200)

    client.submit_samples('[{"name":"web","metrics":{"1000":[]}}]')

    assert_requested request
  end

  def test_submit_samples_returns_nil_on_unauthorized
    stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .to_return(status: 401)

    result = client.submit_samples('[{"name":"web","metrics":{"1000":[]}}]')

    assert_nil result
  end

  def test_submit_samples_raises_on_server_error
    stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .to_return(status: 500)

    error = assert_raises(HireFire::Client::RequestError) do
      client.submit_samples('[{"name":"web","metrics":{"1000":[]}}]')
    end

    assert_includes error.message, "500"
  end

  def test_submit_samples_raises_on_unexpected_status
    stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .to_return(status: 422)

    assert_raises(HireFire::Client::RequestError) do
      client.submit_samples('[{"name":"web","metrics":{"rqt":{"1000":[]}}}]')
    end
  end

  def test_submit_samples_returns_payload_too_large_on_413
    stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .to_return(status: 413, body: '{"error":"payload too large"}')

    assert_equal :payload_too_large, client.submit_samples("[]")
  end

  def test_connection_bypasses_ambient_http_proxy
    ENV["http_proxy"] = "http://proxy.invalid:8080"
    ENV["HTTP_PROXY"] = "http://proxy.invalid:8080"
    ENV["https_proxy"] = "http://proxy.invalid:8080"
    ENV["HTTPS_PROXY"] = "http://proxy.invalid:8080"

    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
    client.submit_samples("[]")
    http = client.instance_variable_get(:@http)

    assert_nil http.proxy_address
    refute http.proxy_from_env?
  ensure
    ENV.delete("http_proxy")
    ENV.delete("HTTP_PROXY")
    ENV.delete("https_proxy")
    ENV.delete("HTTPS_PROXY")
  end

  def test_submit_samples_raises_on_timeout
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_timeout

    error = assert_raises(HireFire::Client::RequestError) do
      client.submit_samples('[{"name":"web","metrics":{"1000":[]}}]')
    end

    assert_includes error.message, "timed out"
  end

  def test_submit_samples_raises_on_transport_errors
    [
      SocketError.new("Failed"),
      Errno::ECONNREFUSED,
      IOError.new("broken pipe"),
      OpenSSL::SSL::SSLError.new("certificate verify failed")
    ].each do |transport_error|
      stub_request(:post, "https://data.hirefire.io/metrics/ingest")
        .to_raise(transport_error)

      error = assert_raises(HireFire::Client::RequestError) do
        client.submit_samples('[{"name":"web","metrics":{"1000":[]}}]')
      end

      assert_includes error.message, "Network error"
    end
  end

  def test_reuses_a_single_connection_across_requests
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)

    client.submit_samples("[]")
    first = client.instance_variable_get(:@http)
    client.submit_samples("[]")
    second = client.instance_variable_get(:@http)

    assert first.started?
    assert_same first, second
  end

  def test_reconnects_and_retries_once_on_a_stale_keep_alive_socket
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
    client.submit_samples("[]")
    established = client.instance_variable_get(:@http)

    stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .to_raise(Errno::ECONNRESET).then
      .to_return(status: 200)

    result = client.submit_samples("[]")

    assert_kind_of Net::HTTPSuccess, result
    refute_same established, client.instance_variable_get(:@http)
  end

  def test_does_not_retry_a_cold_connection_failure
    stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .to_raise(Errno::ECONNRESET).then
      .to_return(status: 200)

    assert_raises(HireFire::Client::RequestError) { client.submit_samples("[]") }
  end

  def test_opens_a_fresh_connection_in_a_forked_child
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
    client.submit_samples("[]")
    inherited = client.instance_variable_get(:@http)

    client.instance_variable_set(:@owner_pid, client.instance_variable_get(:@owner_pid) - 1)
    inherited.expects(:finish).never

    client.submit_samples("[]")
    rebuilt = client.instance_variable_get(:@http)

    refute_same inherited, rebuilt
    assert_equal Process.pid, client.instance_variable_get(:@owner_pid)
  end

  def test_keep_alive_timeout_outlasts_the_max_dispatch_interval
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
    client.submit_samples("[]")

    assert_operator client.instance_variable_get(:@http).keep_alive_timeout, :>, 30
  end

  def test_one_deadline_covers_a_whole_request
    assert_equal 5, HireFire::Client::TIMEOUT
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return do
      sleep(0.3)
      {status: 200}
    end

    error = assert_raises(HireFire::Client::RequestError) do
      HireFire::Client.new(timeout: 0.1).submit_samples("[]")
    end

    assert_equal "Request timed out.", error.message
  end

  def test_a_request_after_one_that_passed_its_deadline_uses_a_new_connection
    slow = true
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return do
      sleep(0.3) if slow
      {status: 200}
    end
    client = HireFire::Client.new(timeout: 0.1)

    assert_raises(HireFire::Client::RequestError) { client.submit_samples("[]") }
    assert_nil client.instance_variable_get(:@http)
    slow = false

    assert_kind_of Net::HTTPSuccess, client.submit_samples("[]")
  end

  def test_open_read_and_write_timeouts_match
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
    client.submit_samples("[]")
    http = client.instance_variable_get(:@http)

    assert_equal 5, http.open_timeout
    assert_equal 5, http.read_timeout
    assert_equal 5, http.write_timeout
  end

  def test_reconnects_and_retries_once_on_a_desynced_keep_alive_response
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
    client.submit_samples("[]")
    established = client.instance_variable_get(:@http)

    stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .to_raise(Net::HTTPBadResponse).then
      .to_return(status: 200)

    result = client.submit_samples("[]")

    assert_kind_of Net::HTTPSuccess, result
    refute_same established, client.instance_variable_get(:@http)
  end

  def test_close_finishes_and_clears_the_persistent_connection
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
    client.submit_samples("[]")
    established = client.instance_variable_get(:@http)

    client.close

    assert established.started? == false
    assert_nil client.instance_variable_get(:@http)
  end

  def test_close_is_safe_without_a_connection
    client.close

    assert_nil client.instance_variable_get(:@http)
  end

  def test_close_swallows_a_failing_connection_shutdown
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
    client.submit_samples("[]")
    established = client.instance_variable_get(:@http)

    established.stubs(:finish).raises(IOError.new("closed stream"))

    client.close

    assert_nil client.instance_variable_get(:@http)
  end

  def test_request_lease_sends_process_id
    request = stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .with(headers: {
        "HireFire-Token" => "test-token-value",
        "HireFire-Agent" => "Ruby-#{HireFire::VERSION}",
        "HireFire-Process-ID" => "abc123"
      })
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "false",
        "HireFire-Sample-Frequency" => "15"
      })

    client.request_lease("abc123")

    assert_requested request
  end

  def test_a_response_whose_declared_length_is_over_the_limit_is_refused_before_its_body_is_read
    stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .to_return(status: 200, headers: {"Content-Length" => (HireFire::Client::MAX_BODY_BYTES + 1).to_s}, body: "short")

    error = assert_raises(HireFire::Client::RequestError) { client.request_lease("abc123") }

    assert_equal "Response body exceeded 131072 bytes (status 200).", error.message
  end

  def test_a_response_body_over_the_limit_is_refused_and_the_connection_is_dropped
    stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .to_return(status: 500, body: "x" * (HireFire::Client::MAX_BODY_BYTES + 1))
      .then.to_return(status: 200)

    error = assert_raises(HireFire::Client::RequestError) { client.submit_samples("[]") }

    assert_equal "Response body exceeded 131072 bytes (status 500).", error.message
    assert_nil client.instance_variable_get(:@http)
    assert_kind_of Net::HTTPSuccess, client.submit_samples("[]")
  end

  def test_a_response_body_of_exactly_the_limit_is_read_in_full
    body = "x" * HireFire::Client::MAX_BODY_BYTES
    stub_request(:post, "https://data.hirefire.io/metrics/lease").to_return(status: 200, body: body)

    assert_equal 131_072, HireFire::Client::MAX_BODY_BYTES
    assert_equal body, client.request_lease("abc123").body
  end

  def test_a_response_without_a_body_reads_as_an_empty_string
    stub_request(:post, "https://data.hirefire.io/metrics/lease").to_return(status: 200)

    assert_equal "", client.request_lease("abc123").body
  end

  def test_header_integer_reads_positive_whole_numbers_only
    response = {"plain" => "30", "padded" => " 7 ", "zero" => "0", "negative" => "-5", "words" => "soon", "mixed" => "3abc", "decimal" => "1.5", "grouped" => "1_000", "empty" => ""}

    assert_equal 30, HireFire::Client.header_integer(response, "plain")
    assert_equal 7, HireFire::Client.header_integer(response, "padded")
    %w[zero negative words mixed decimal grouped empty missing].each do |name|
      assert_nil HireFire::Client.header_integer(response, name), "#{name} was read as a number"
    end
  end

  def test_request_lease_raises_on_timeout
    stub_request(:post, "https://data.hirefire.io/metrics/lease").to_timeout

    assert_raises(HireFire::Client::RequestError) do
      client.request_lease("abc123")
    end
  end

  def test_raises_without_token
    ENV["HIREFIRE_TOKEN"] = nil

    error = assert_raises(HireFire::Client::RequestError) do
      client.submit_samples("[]")
    end

    assert_includes error.message, "HIREFIRE_TOKEN"
    assert_includes error.message, "config.token"
  end

  def test_raises_with_empty_token
    ENV["HIREFIRE_TOKEN"] = ""

    error = assert_raises(HireFire::Client::RequestError) do
      client.submit_samples("[]")
    end

    assert_includes error.message, "HIREFIRE_TOKEN"
  end

  def test_blank_and_slash_only_data_url_falls_back_to_default
    ["", "   ", "/", "///"].each do |value|
      ENV["HIREFIRE_DATA_URL"] = value
      fresh = HireFire::Client.new
      assert_equal "https://data.hirefire.io", fresh.send(:base_url),
        "expected default base for #{value.inspect}"
    end
  ensure
    ENV.delete("HIREFIRE_DATA_URL")
  end

  def test_whitespace_padded_data_url_is_stripped
    ENV["HIREFIRE_DATA_URL"] = "  https://custom.hirefire.io  "
    custom_client = HireFire::Client.new

    request = stub_request(:post, "https://custom.hirefire.io/metrics/ingest")
      .to_return(status: 200)

    custom_client.submit_samples('[{"name":"web","metrics":{"1000":[]}}]')

    assert_requested request
  ensure
    ENV.delete("HIREFIRE_DATA_URL")
  end

  def test_custom_data_url
    ENV["HIREFIRE_DATA_URL"] = "https://custom.hirefire.io"
    custom_client = HireFire::Client.new

    request = stub_request(:post, "https://custom.hirefire.io/metrics/ingest")
      .to_return(status: 200)

    custom_client.submit_samples('[{"name":"web","metrics":{"1000":[]}}]')

    assert_requested request
  end

  def test_custom_data_url_over_plain_http
    ENV["HIREFIRE_DATA_URL"] = "http://localhost:9999"
    custom_client = HireFire::Client.new

    request = stub_request(:post, "http://localhost:9999/metrics/ingest")
      .to_return(status: 200)

    custom_client.submit_samples('[{"name":"web","metrics":{"1000":[]}}]')

    assert_requested request
  end

  def test_a_plain_http_data_url_on_another_host_warns_once_that_the_token_is_sent_in_clear_text
    ENV["HIREFIRE_DATA_URL"] = "http://collector.example.com:8080"
    stub_request(:post, %r{\Ahttp://collector\.example\.com:8080/metrics/}).to_return(status: 200)

    client.submit_samples("[]")
    client.request_lease("abc123")
    HireFire::Client.new.submit_samples("[]")

    assert_equal 1, log.string.scan("HIREFIRE_DATA_URL uses http, so the HireFire token is sent to collector.example.com in clear text. Use an https URL.").size
  ensure
    ENV.delete("HIREFIRE_DATA_URL")
  end

  def test_a_plain_http_data_url_on_this_host_and_an_https_url_do_not_warn
    ["http://localhost:9999", "http://127.0.0.1:9999", "http://[::1]:9999", "https://collector.example.com"].each do |url|
      ENV["HIREFIRE_DATA_URL"] = url
      stub_request(:post, "#{url}/metrics/ingest").to_return(status: 200)

      HireFire::Client.new.submit_samples("[]")
    end

    assert_empty log.string
  ensure
    ENV.delete("HIREFIRE_DATA_URL")
  end

  def test_a_data_url_that_is_not_an_http_url_with_a_host_fails_the_request_with_a_reason
    ["collector.example.com", "ftp://collector.example.com", "https://", "ht tp://collector.example.com", "//collector.example.com"].each do |url|
      ENV["HIREFIRE_DATA_URL"] = url

      error = assert_raises(HireFire::Client::RequestError, "#{url.inspect} was accepted") do
        HireFire::Client.new.submit_samples("[]")
      end
      assert_equal "HIREFIRE_DATA_URL must be an http or https URL with a host.", error.message
    end
  ensure
    ENV.delete("HIREFIRE_DATA_URL")
  end

  def test_custom_data_url_with_a_trailing_slash_does_not_double_the_path
    ENV["HIREFIRE_DATA_URL"] = "https://custom.hirefire.io/prefix/"
    custom_client = HireFire::Client.new

    request = stub_request(:post, "https://custom.hirefire.io/prefix/metrics/ingest")
      .to_return(status: 200)

    custom_client.submit_samples('[{"name":"web","metrics":{"1000":[]}}]')

    assert_requested request
  end

  def test_custom_data_url_honors_a_path_prefix
    ENV["HIREFIRE_DATA_URL"] = "https://proxy.example.com/hf"
    custom_client = HireFire::Client.new

    request = stub_request(:post, "https://proxy.example.com/hf/metrics/ingest")
      .to_return(status: 200)

    custom_client.submit_samples('[{"name":"web","metrics":{"1000":[]}}]')

    assert_requested request
  end

  def test_request_lease_sends_the_agent_header
    request = stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .with(headers: {"HireFire-Agent" => "Ruby-#{HireFire::VERSION}"})
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "false",
        "HireFire-Sample-Frequency" => "15"
      })

    client.request_lease("abc123")

    assert_requested request
  end

  def test_retries_once_on_each_stale_connection_error
    [
      EOFError.new("end of file"),
      Errno::ECONNABORTED.new,
      Errno::EPIPE.new,
      Net::ProtocolError.new("protocol error")
    ].each do |error|
      fresh = HireFire::Client.new
      stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
      fresh.submit_samples("[]")

      stub_request(:post, "https://data.hirefire.io/metrics/ingest")
        .to_raise(error).then
        .to_return(status: 200)

      result = fresh.submit_samples("[]")
      assert_kind_of Net::HTTPSuccess, result, error.class.name
    end
  end

  def test_does_not_retry_twice_on_persistent_stale_errors
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
    client.submit_samples("[]")
    WebMock.reset_executed_requests!

    request = stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .to_raise(Errno::ECONNRESET).then
      .to_raise(Errno::ECONNRESET)

    assert_raises(HireFire::Client::RequestError) { client.submit_samples("[]") }
    assert_requested request, times: 2
  end

  def test_reconnects_when_host_or_port_changes
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_return(status: 200)
    client.submit_samples("[]")
    first = client.instance_variable_get(:@http)

    ENV["HIREFIRE_DATA_URL"] = "https://other.example.com"
    other = HireFire::Client.new
    stub_request(:post, "https://other.example.com/metrics/ingest").to_return(status: 200)
    other.submit_samples("[]")
    second = other.instance_variable_get(:@http)

    refute_same first, second
    assert_equal "other.example.com", second.address
  ensure
    ENV.delete("HIREFIRE_DATA_URL")
  end
end
