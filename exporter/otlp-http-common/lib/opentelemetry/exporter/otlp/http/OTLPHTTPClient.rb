# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require 'opentelemetry/common'
require 'net/http'

module OpenTelemetry
  module Exporter
    module OTLP
      module HTTP
        class OTLPHTTPClient < Net::HTTP
          class << self
            def new(options, service, base_path)
              obj = allocate
              obj.send(:initialize, options, service, base_path)
              obj
            end
          end

          # Default timeouts in seconds.
          KEEP_ALIVE_TIMEOUT = 30
          private_constant(:KEEP_ALIVE_TIMEOUT)
          
          def initialize(options, service, base_path = '')
            if options.nil?
              options = OpenTelemetry::Exporter::OTLP::HTTP::OTLPHTTPClientConfig.new(
                certificate_file: OpenTelemetry::Common::Utilities.config_opt("#{service}_CERTIFICATE", 'OTEL_EXPORTER_OTLP_CERTIFICATE'),
                client_certificate_file: OpenTelemetry::Common::Utilities.config_opt("#{service}_CLIENT_CERTIFICATE", 'OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE'),
                client_key_file: OpenTelemetry::Common::Utilities.config_opt("#{service}_CLIENT_KEY", 'OTEL_EXPORTER_OTLP_CLIENT_KEY'),
                endpoint: OpenTelemetry::Common::Utilities.config_opt("#{service}_ENDPOINT", 'OTEL_EXPORTER_OTLP_ENDPOINT', default: "http://localhost:4318/#{base_path}"),
                ssl_verify_mode: ssl_verify_mode
              )
            end

            uri = URI(options.endpoint)
            super(uri.hostname, uri.port)
            
            self.use_ssl = uri.scheme == 'https'
            self.verify_mode = options. ssl_verify_mode

            self.ca_file = options.certificate_file if options.certificate_file

            if options.client_certificate_file
              self.cert = OpenSSL::X509::Certificate.new(File.read(options.client_certificate_file))
            end

            if options.client_key_file
              self.key = OpenSSL::PKey::RSA.new(File.read(options.client_key_file))
            end

            self.keep_alive_timeout = KEEP_ALIVE_TIMEOUT
          end

          private

          def ssl_verify_mode
            if ENV['OTEL_RUBY_EXPORTER_OTLP_SSL_VERIFY_PEER'] == 'true'
              OpenSSL::SSL::VERIFY_PEER
            elsif ENV['OTEL_RUBY_EXPORTER_OTLP_SSL_VERIFY_NONE'] == 'true'
              OpenSSL::SSL::VERIFY_NONE
            else
              OpenSSL::SSL::VERIFY_PEER
            end
          end
        end
      end
    end
  end
end
