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

  def test_submit_samples_sends_payload
    request = stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .with(
        body: '[{"name":"web","samples":{"1000":[]}}]',
        headers: {
          "Content-Type" => "application/json",
          "HireFire-Token" => "test-token-value",
          "HireFire-Agent" => "Ruby-#{HireFire::VERSION}"
        }
      )
      .to_return(status: 200)

    client.submit_samples('[{"name":"web","samples":{"1000":[]}}]')

    assert_requested request
  end

  def test_submit_samples_returns_nil_on_unauthorized
    stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .to_return(status: 401)

    result = client.submit_samples('[{"name":"web","samples":{"1000":[]}}]')

    assert_nil result
  end

  def test_submit_samples_raises_on_server_error
    stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .to_return(status: 500)

    error = assert_raises(HireFire::Client::RequestError) do
      client.submit_samples('[{"name":"web","samples":{"1000":[]}}]')
    end

    assert_includes error.message, "500"
  end

  def test_submit_samples_raises_on_unexpected_status
    stub_request(:post, "https://data.hirefire.io/metrics/ingest")
      .to_return(status: 422)

    assert_raises(HireFire::Client::RequestError) do
      client.submit_samples('[{"name":"web","samples":{"1000":[]}}]')
    end
  end

  def test_submit_samples_raises_on_timeout
    stub_request(:post, "https://data.hirefire.io/metrics/ingest").to_timeout

    error = assert_raises(HireFire::Client::RequestError) do
      client.submit_samples('[{"name":"web","samples":{"1000":[]}}]')
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
        client.submit_samples('[{"name":"web","samples":{"1000":[]}}]')
      end

      assert_includes error.message, "Network error"
    end
  end

  def test_request_lease_sends_process_id
    request = stub_request(:post, "https://data.hirefire.io/metrics/lease")
      .with(headers: {
        "HireFire-Token" => "test-token-value",
        "HireFire-Process-ID" => "abc123"
      })
      .to_return(status: 200, headers: {
        "HireFire-Lease-Granted" => "false",
        "HireFire-Sample-Frequency" => "15"
      })

    client.request_lease("abc123")

    assert_requested request
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
  end

  def test_custom_data_url
    ENV["HIREFIRE_DATA_URL"] = "https://custom.hirefire.io"
    custom_client = HireFire::Client.new

    request = stub_request(:post, "https://custom.hirefire.io/metrics/ingest")
      .to_return(status: 200)

    custom_client.submit_samples('[{"name":"web","samples":{"1000":[]}}]')

    assert_requested request
  end
end
