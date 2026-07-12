# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0
require 'test_helper'
require 'google/protobuf/wrappers_pb'
require 'google/protobuf/well_known_types'

describe OpenTelemetry::Exporter::OTLP::Common::OTLPClient do
  DEFAULT_USER_AGENT = OpenTelemetry::Exporter::OTLP::Common::OTLPClient::DEFAULT_USER_AGENT
  CLIENT_CERT_A_PATH = File.dirname(__FILE__) + '/mtls-client-a.pem'
  CLIENT_CERT_A = OpenSSL::X509::Certificate.new(File.read(CLIENT_CERT_A_PATH))
  CLIENT_KEY_A = OpenSSL::PKey::RSA.new(File.read(CLIENT_CERT_A_PATH))
  CLIENT_CERT_B_PATH = File.dirname(__FILE__) + '/mtls-client-b.pem'
  CLIENT_CERT_B = OpenSSL::X509::Certificate.new(File.read(CLIENT_CERT_B_PATH))
  CLIENT_KEY_B = OpenSSL::PKey::RSA.new(File.read(CLIENT_CERT_B_PATH))

  describe '#initialize' do
    it 'initializes with defaults' do
      exp = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new
      _(exp).wont_be_nil
      _(exp.instance_variable_get(:@headers)).must_equal('User-Agent' => DEFAULT_USER_AGENT)
      _(exp.instance_variable_get(:@timeout)).must_equal 10.0
      _(exp.instance_variable_get(:@path)).must_equal '/'
      _(exp.instance_variable_get(:@compression)).must_equal 'gzip'
      http = exp.instance_variable_get(:@http)
      _(http.ca_file).must_be_nil
      _(http.cert).must_be_nil
      _(http.key).must_be_nil
      _(http.use_ssl?).must_equal false
      _(http.address).must_equal 'localhost'
      _(http.verify_mode).must_equal OpenSSL::SSL::VERIFY_PEER
      _(http.port).must_equal 4318
    end

    it 'uses endpoints path if provided' do
      exp = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(uri: URI('https://localhost/custom/path'))
      _(exp.instance_variable_get(:@path)).must_equal '/custom/path'
    end

    it 'only allows gzip compression or none' do
      assert_raises ArgumentError do
        OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(compression: 'flate')
      end
      exp = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(compression: nil)
      _(exp.instance_variable_get(:@compression)).must_be_nil

      %w[gzip none].each do |compression|
        exp = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(compression: compression)
        _(exp.instance_variable_get(:@compression)).must_equal(compression)
      end
    end

    it 'restricts explicit headers to a String or Hash' do
      exp = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(headers: { 'token' => 'über' })
      _(exp.instance_variable_get(:@headers)).must_equal('token' => 'über', 'User-Agent' => DEFAULT_USER_AGENT)

      exp = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(headers: 'token=%C3%BCber')
      _(exp.instance_variable_get(:@headers)).must_equal('token' => 'über', 'User-Agent' => DEFAULT_USER_AGENT)

      error = _ do
        exp = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(headers: Object.new)
        _(exp.instance_variable_get(:@headers)).must_equal('token' => 'über')
      end.must_raise(ArgumentError)
      _(error.message).must_match(/headers/i)
    end

    it 'ignores later mutations of a headers Hash parameter' do
      a_hash_to_mutate_later = { 'token' => 'über' }
      exp = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(headers: a_hash_to_mutate_later)
      _(exp.instance_variable_get(:@headers)).must_equal('token' => 'über', 'User-Agent' => DEFAULT_USER_AGENT)

      a_hash_to_mutate_later['token'] = 'unter'
      a_hash_to_mutate_later['oops'] = 'i forgot to add this, too'
      _(exp.instance_variable_get(:@headers)).must_equal('token' => 'über', 'User-Agent' => DEFAULT_USER_AGENT)
    end

    describe 'Headers Environment Variable' do
      it 'allows any number of the equal sign (=) characters in the value' do
        exp = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(headers: 'a=b,c=d==,e=f')
        _(exp.instance_variable_get(:@headers)).must_equal('a' => 'b', 'c' => 'd==', 'e' => 'f', 'User-Agent' => DEFAULT_USER_AGENT)
      end

      it 'trims any leading or trailing whitespaces in keys and values' do
        exp = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(headers: 'a =  b  ,c=d , e=f')
        _(exp.instance_variable_get(:@headers)).must_equal('a' => 'b', 'c' => 'd', 'e' => 'f', 'User-Agent' => DEFAULT_USER_AGENT)
      end

      it 'decodes values as URL encoded UTF-8 strings' do
        exp = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(headers: 'token=%C3%BCber')
        _(exp.instance_variable_get(:@headers)).must_equal('token' => 'über', 'User-Agent' => DEFAULT_USER_AGENT)

        exp = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(headers: '%C3%BCber=token')
        _(exp.instance_variable_get(:@headers)).must_equal('über' => 'token', 'User-Agent' => DEFAULT_USER_AGENT)
      end

      it 'appends the default user agent to one provided in config' do
        exp = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(headers: 'User-Agent=%C3%BCber/3.2.1')
        _(exp.instance_variable_get(:@headers)).must_equal('User-Agent' => "über/3.2.1 #{DEFAULT_USER_AGENT}")
      end

      it 'fails fast when header values are missing' do
        error = _ do
          OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(headers: 'a = ')
        end.must_raise(ArgumentError)
        _(error.message).must_match(/headers/i)
      end

      it 'fails fast when header or values are not found' do
        error = _ do
          OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(headers: ',')
        end.must_raise(ArgumentError)
        _(error.message).must_match(/headers/i)
      end

      it 'fails fast when header values contain invalid escape characters' do
        error = _ do
          OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(headers: 'c=hi%F3')
        end.must_raise(ArgumentError)
        _(error.message).must_match(/headers/i)
      end

      it 'fails fast when headers are invalid' do
        error = _ do
          OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(headers: 'this is not a header')
        end.must_raise(ArgumentError)
        _(error.message).must_match(/headers/i)
      end
    end
  end

  describe 'ssl_verify_mode:' do
    it 'can be set to VERIFY_NONE by an envvar' do
      exp = OpenTelemetry::TestHelpers.with_env('OTEL_RUBY_EXPORTER_OTLP_SSL_VERIFY_NONE' => 'true') do
        OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new
      end
      http = exp.instance_variable_get(:@http)
      _(http.verify_mode).must_equal OpenSSL::SSL::VERIFY_NONE
    end

    it 'can be set to VERIFY_PEER by an envvar' do
      exp = OpenTelemetry::TestHelpers.with_env('OTEL_RUBY_EXPORTER_OTLP_SSL_VERIFY_PEER' => 'true') do
        OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new
      end
      http = exp.instance_variable_get(:@http)
      _(http.verify_mode).must_equal OpenSSL::SSL::VERIFY_PEER
    end

    it 'VERIFY_PEER will override VERIFY_NONE' do
      exp = OpenTelemetry::TestHelpers.with_env('OTEL_RUBY_EXPORTER_OTLP_SSL_VERIFY_NONE' => 'true',
                                                'OTEL_RUBY_EXPORTER_OTLP_SSL_VERIFY_PEER' => 'true') do
        OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new
      end
      http = exp.instance_variable_get(:@http)
      _(http.verify_mode).must_equal OpenSSL::SSL::VERIFY_PEER
    end
  end

  describe 'IPv4/IPv6 compatibility' do
    it 'handles IPv6 loopback address with brackets' do
      exp = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(uri: URI('http://[::1]:4318/v1/logs'))
      http = exp.instance_variable_get(:@http)
      _(http.address).must_equal '::1'
      _(http.port).must_equal 4318
      _(exp.instance_variable_get(:@path)).must_equal '/v1/logs'
    end

    it 'handles IPv6 full address with brackets' do
      exp = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(uri: URI('http://[2001:db8::1]:4318/v1/logs'))
      http = exp.instance_variable_get(:@http)
      _(http.address).must_equal '2001:db8::1'
      _(http.port).must_equal 4318
    end

    it 'handles IPv6 address with https' do
      exp = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(uri: URI('https://[::1]:4318/v1/logs'))
      http = exp.instance_variable_get(:@http)
      _(http.address).must_equal '::1'
      _(http.port).must_equal 4318
      _(http.use_ssl?).must_equal true
    end

    it 'handles IPv6 address with custom path' do
      exp = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(uri: URI('http://[::1]:8080/custom/path'))
      http = exp.instance_variable_get(:@http)
      _(http.address).must_equal '::1'
      _(http.port).must_equal 8080
      _(exp.instance_variable_get(:@path)).must_equal '/custom/path'
    end

    it 'handles IPv4 loopback address' do
      exp = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(uri: URI('http://127.0.0.1:4318/v1/logs'))
      http = exp.instance_variable_get(:@http)
      _(http.address).must_equal '127.0.0.1'
      _(http.port).must_equal 4318
      _(exp.instance_variable_get(:@path)).must_equal '/v1/logs'
    end

    it 'handles IPv4 address with custom port' do
      exp = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(uri: URI('http://192.168.1.100:8080/v1/logs'))
      http = exp.instance_variable_get(:@http)
      _(http.address).must_equal '192.168.1.100'
      _(http.port).must_equal 8080
    end

    it 'handles IPv4 address with https' do
      exp = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(uri: URI('https://10.0.0.1:4318/v1/logs'))
      http = exp.instance_variable_get(:@http)
      _(http.address).must_equal '10.0.0.1'
      _(http.port).must_equal 4318
      _(http.use_ssl?).must_equal true
    end

    it 'handles IPv4 address with custom path' do
      exp = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(uri: URI('http://127.0.0.1:9090/custom/path'))
      http = exp.instance_variable_get(:@http)
      _(http.address).must_equal '127.0.0.1'
      _(http.port).must_equal 9090
      _(exp.instance_variable_get(:@path)).must_equal '/custom/path'
    end

    it 'handles hostnames' do
      exp = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(uri: URI('http://localhost:4318/v1/logs'))
      http = exp.instance_variable_get(:@http)
      _(http.address).must_equal 'localhost'
      _(http.port).must_equal 4318
    end

    it 'handles fully qualified domain names' do
      exp = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(uri: URI('http://otel.example.com:4318/v1/logs'))
      http = exp.instance_variable_get(:@http)
      _(http.address).must_equal 'otel.example.com'
      _(http.port).must_equal 4318
    end

    it 'handles hostnames with https' do
      exp = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(uri: URI('https://otel-collector.prod.example.com:443/v1/logs'))
      http = exp.instance_variable_get(:@http)
      _(http.address).must_equal 'otel-collector.prod.example.com'
      _(http.port).must_equal 443
      _(http.use_ssl?).must_equal true
    end
  end

  describe '#export' do
    let(:exporter) { OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new }
    # TODO: replace with a before block to set a global logger provider through OpenTelemetry.logger_provider when the API code is merged
    let(:logger_provider) { OpenTelemetry::SDK::Logs::LoggerProvider.new(resource: OpenTelemetry::SDK::Resources::Resource.telemetry_sdk) }

    it 'integrates with collector' do
      skip unless ENV['TRACING_INTEGRATION_TEST']
      WebMock.disable_net_connect!(allow: 'localhost')
      exporter = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(uri: 'http://localhost:4318', compression: 'gzip')
      result = exporter.send_bytes('random'.b)
      _(result.success).must_equal(true)
    end

    it 'retries on timeout' do
      stub_request(:post, 'http://localhost:4318').to_timeout.then.to_return(status: 200)
      result = exporter.send_bytes('random'.b)
      _(result.success).must_equal(true)
    end

    it 'returns FAILURE on timeout' do
      stub_request(:post, 'http://localhost:4318').to_return(status: 200)
      result = exporter.send_bytes('random'.b, timeout: 0)
      _(result.success).must_equal(false)
    end

    it 'returns FAILURE on unexpected exceptions' do
      log_stream = StringIO.new
      logger = OpenTelemetry.logger
      OpenTelemetry.logger = ::Logger.new(log_stream)

      stub_request(:post, 'http://localhost:4318').to_raise('something unexpected')
      result = exporter.send_bytes('random'.b, timeout: 1)

      _(log_stream.string).must_match(
        /ERROR -- : OpenTelemetry error: unexpected error in OTLP::Exporter#send_bytes - something unexpected/
      )

      _(result.success).must_equal(false)
    ensure
      OpenTelemetry.logger = logger
    end

    { 'Net::HTTPServiceUnavailable' => 503,
      'Net::HTTPTooManyRequests' => 429,
      'Net::HTTPRequestTimeout' => 408,
      'Net::HTTPGatewayTimeout' => 504,
      'Net::HTTPBadGateway' => 502,
      'Net::HTTPNotFound' => 404 }.each do |klass, code|
      it "logs an error and returns FAILURE with #{code}s" do
        OpenTelemetry::Exporter::OTLP::Common::OTLPClient.stub_const(:RETRY_COUNT, 0) do
          log_stream = StringIO.new
          OpenTelemetry.logger = ::Logger.new(log_stream)

          stub_request(:post, 'http://localhost:4318').to_return(status: code)
          _(exporter.send_bytes('random'.b).success).must_equal(false)
          _(log_stream.string).must_match(
            %r{ERROR -- : OpenTelemetry error: OTLP exporter received #{klass}, http.code=#{code}, uri='http://localhost:4318/'}
          )
        end
      end
    end

    [
      Net::OpenTimeout,
      Net::ReadTimeout,
      OpenSSL::SSL::SSLError,
      SocketError,
      EOFError,
      Zlib::DataError
    ].each do |error|
      it "logs error and returns FAILURE when #{error} is raised" do
        OpenTelemetry::Exporter::OTLP::Common::OTLPClient.stub_const(:RETRY_COUNT, 0) do
          log_stream = StringIO.new
          OpenTelemetry.logger = ::Logger.new(log_stream)

          stub_request(:post, 'http://localhost:4318').to_raise(error.send(:new))
          _(exporter.send_bytes('random'.b).success).must_equal(false)
          _(log_stream.string).must_match(
            /ERROR -- : OpenTelemetry error: #{error}/
          )
        end
      end
    end

    it 'works with a SystemCallError' do
      OpenTelemetry::Exporter::OTLP::Common::OTLPClient.stub_const(:RETRY_COUNT, 0) do
        log_stream = StringIO.new
        OpenTelemetry.logger = ::Logger.new(log_stream)
        stub_request(:post, 'http://localhost:4318').to_raise(SystemCallError.new('Failed to open TCP connection', 61))
        _(exporter.send_bytes('random'.b).success).must_equal(false)
        _(log_stream.string).must_match(
          /ERROR -- : OpenTelemetry error:.*Failed to open TCP connection/
        )
      end
    end

    it 'returns FAILURE on timeout after retrying' do
      stub_request(:post, 'http://localhost:4318').to_timeout.then.to_raise('this should not be reached')

      @retry_count = 0
      backoff_stubbed_call = lambda do |**_args|
        sleep(0.10)
        @retry_count += 1
        true
      end

      exporter.stub(:backoff?, backoff_stubbed_call) do
        _(exporter.send_bytes('random'.b, timeout: 0.1).success).must_equal(false)
      end
    ensure
      @retry_count = 0
    end

    it 'returns FAILURE when encryption to receiver endpoint fails' do
      log_stream = StringIO.new
      OpenTelemetry.logger = ::Logger.new(log_stream)

      exporter = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(uri: URI('https://localhost:4318/v1/logs'))
      stub_request(:post, 'https://localhost:4318/v1/logs').to_raise(OpenSSL::SSL::SSLError.new('enigma wedged'))
      exporter.stub(:backoff?, ->(**_) { false }) do
        _(exporter.send_bytes('random'.b).success).must_equal(false)

        _(log_stream.string).must_match(
          /ERROR -- : OpenTelemetry error: enigma wedged/
        )
      end
    end

    it 'exports a log_record_data' do
      stub_request(:post, 'http://localhost:4318').to_return(status: 200)
      result = exporter.send_bytes('random'.b)
      _(result.success).must_equal(true)
    end

    it 'logs a specific message when there is a 404' do
      log_stream = StringIO.new
      logger = OpenTelemetry.logger
      OpenTelemetry.logger = ::Logger.new(log_stream)

      stub_request(:post, 'http://localhost:4318').to_return(status: 404, body: "Not Found\n")

      result = exporter.send_bytes('random'.b)

      _(log_stream.string).must_match(
        %r{ERROR -- : OpenTelemetry error: OTLP exporter received Net::HTTPNotFound, http.code=404, uri='http://localhost:4318/'\n}
      )

      _(result.success).must_equal(false)
    ensure
      OpenTelemetry.logger = logger
    end

    it 'handles Zlib gzip compression errors' do
      stub_request(:post, 'http://localhost:4318').to_raise(Zlib::DataError.new('data error'))
      exporter.stub(:backoff?, ->(**_) { false }) do
        _(exporter.send_bytes('random'.b).success).must_equal(false)
      end
    end
  end
end
