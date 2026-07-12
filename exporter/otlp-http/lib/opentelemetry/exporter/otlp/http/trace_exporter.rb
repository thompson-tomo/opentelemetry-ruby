# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require 'opentelemetry/common'
require 'opentelemetry/exporter/otlp_common'
require 'opentelemetry/exporter/otlp/common'
require 'opentelemetry/sdk'
require 'net/http'
require 'zlib'

require 'google/rpc/status_pb'

module OpenTelemetry
  module Exporter
    module OTLP
      module HTTP
        # An OpenTelemetry trace exporter that sends spans over HTTP as Protobuf encoded OTLP ExportTraceServiceRequests.
        class TraceExporter
          DEFAULT_USER_AGENT = "OTel-OTLP-Exporter-Ruby/#{OpenTelemetry::Exporter::OTLP::HTTP::VERSION}".freeze

          def initialize(endpoint: nil,
                         certificate_file: OpenTelemetry::Common::Utilities.config_opt('OTEL_EXPORTER_OTLP_TRACES_CERTIFICATE', 'OTEL_EXPORTER_OTLP_CERTIFICATE'),
                         client_certificate_file: OpenTelemetry::Common::Utilities.config_opt('OTEL_EXPORTER_OTLP_TRACES_CLIENT_CERTIFICATE', 'OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE'),
                         client_key_file: OpenTelemetry::Common::Utilities.config_opt('OTEL_EXPORTER_OTLP_TRACES_CLIENT_KEY', 'OTEL_EXPORTER_OTLP_CLIENT_KEY'),
                         ssl_verify_mode: nil,
                         headers: OpenTelemetry::Common::Utilities.config_opt('OTEL_EXPORTER_OTLP_TRACES_HEADERS', 'OTEL_EXPORTER_OTLP_HEADERS', default: {}),
                         compression: OpenTelemetry::Common::Utilities.config_opt('OTEL_EXPORTER_OTLP_TRACES_COMPRESSION', 'OTEL_EXPORTER_OTLP_COMPRESSION', default: 'gzip'),
                         timeout: OpenTelemetry::Common::Utilities.config_opt('OTEL_EXPORTER_OTLP_TRACES_TIMEOUT', 'OTEL_EXPORTER_OTLP_TIMEOUT', default: 10))
            raise ArgumentError, "unsupported compression key #{compression}" unless compression.nil? || %w[gzip none].include?(compression)

            @uri = prepare_endpoint(endpoint)

            @client = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(uri: @uri, type: 'metrics', useragent: DEFAULT_USER_AGENT, certificate_file: certificate_file, client_certificate_file: client_certificate_file, client_key_file: client_key_file, ssl_verify_mode: ssl_verify_mode, headers: headers, compression: compression, timeout: timeout)
            @http = @client.instance_variable_get(:@http)

            @path = @uri.path
            @headers = headers
            @timeout = timeout.to_f
            @compression = compression
            @shutdown = false
          end

          # Called to export sampled {OpenTelemetry::SDK::Trace::SpanData} structs.
          #
          # @param [Enumerable<OpenTelemetry::SDK::Trace::SpanData>] span_data the
          #   list of recorded {OpenTelemetry::SDK::Trace::SpanData} structs to be
          #   exported.
          # @param [optional Numeric] timeout An optional timeout in seconds.
          # @return [Integer] the result of the export.
          def export(span_data, timeout: nil)
            return OpenTelemetry::SDK::Trace::Export::FAILURE if @shutdown

            result = @client.send_bytes(OpenTelemetry::Exporter::OTLP::Common.as_encoded_etsr(span_data), timeout: timeout)
            log_status(result.response.body) unless result.response.nil?
            result.success ? OpenTelemetry::SDK::Trace::Export::SUCCESS : OpenTelemetry::SDK::Trace::Export::FAILURE
          end

          # Called when {OpenTelemetry::SDK::Trace::TracerProvider#force_flush} is called, if
          # this exporter is registered to a {OpenTelemetry::SDK::Trace::TracerProvider}
          # object.
          #
          # @param [optional Numeric] timeout An optional timeout in seconds.
          def force_flush(timeout: nil)
            OpenTelemetry::SDK::Trace::Export::SUCCESS
          end

          # Called when {OpenTelemetry::SDK::Trace::TracerProvider#shutdown} is called, if
          # this exporter is registered to a {OpenTelemetry::SDK::Trace::TracerProvider}
          # object.
          #
          # @param [optional Numeric] timeout An optional timeout in seconds.
          def shutdown(timeout: nil)
            @shutdown = true
            @client.finish if @client.started?
            OpenTelemetry::SDK::Trace::Export::SUCCESS
          end

          private

          def log_status(body)
            status = Google::Rpc::Status.decode(body)
            pool = ::Google::Protobuf::DescriptorPool.generated_pool
            details = status.details.filter_map do |detail|
              klass = pool.lookup(detail.type_name).msgclass
              detail.unpack(klass) if klass
            end
            OpenTelemetry.handle_error(message: "OTLP exporter received rpc.Status{message=#{status.message}, details=#{details}}")
          rescue StandardError => e
            OpenTelemetry.handle_error(exception: e, message: 'unexpected error decoding rpc.Status in OTLP::Exporter#log_status')
          end

          def prepare_endpoint(endpoint)
            endpoint ||= ENV.fetch('OTEL_EXPORTER_OTLP_TRACES_ENDPOINT', nil)
            if endpoint.nil?
              endpoint = ENV['OTEL_EXPORTER_OTLP_ENDPOINT'] || 'http://localhost:4318'
              endpoint += '/' unless endpoint.end_with?('/')
              URI.join(endpoint, 'v1/traces')
            elsif endpoint.strip.empty?
              raise ArgumentError, "invalid url for OTLP::Exporter #{endpoint}"
            else
              URI(endpoint)
            end
          rescue URI::InvalidURIError
            raise ArgumentError, "invalid url for OTLP::Exporter #{endpoint}"
          end
        end
      end
    end
  end
end
