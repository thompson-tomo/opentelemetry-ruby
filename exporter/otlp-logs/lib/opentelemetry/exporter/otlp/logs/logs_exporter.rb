# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require 'opentelemetry/common'
require 'opentelemetry/exporter/otlp_common'
require 'opentelemetry/sdk'
require 'opentelemetry-logs-api' # the sdk isn't loading the api, but not sure why
require 'opentelemetry/sdk/logs'
require 'net/http'
require 'zlib'

require 'google/rpc/status_pb'

require 'opentelemetry/proto/common/v1/common_pb'
require 'opentelemetry/proto/resource/v1/resource_pb'
require 'opentelemetry/proto/logs/v1/logs_pb'
require 'opentelemetry/proto/collector/logs/v1/logs_service_pb'

module OpenTelemetry
  module Exporter
    module OTLP
      module Logs
        # An OpenTelemetry log exporter that sends log records over HTTP as Protobuf encoded OTLP ExportLogsServiceRequests.
        class LogsExporter # rubocop:disable Metrics/ClassLength
          DEFAULT_USER_AGENT = "OTel-OTLP-Exporter-Ruby/#{OpenTelemetry::Exporter::OTLP::Logs::VERSION} Ruby/#{RUBY_VERSION} (#{RUBY_PLATFORM}; #{RUBY_ENGINE}/#{RUBY_ENGINE_VERSION})".freeze

          def initialize(endpoint: OpenTelemetry::Common::Utilities.config_opt('OTEL_EXPORTER_OTLP_LOGS_ENDPOINT', 'OTEL_EXPORTER_OTLP_ENDPOINT', default: 'http://localhost:4318/v1/logs'),
                         certificate_file: OpenTelemetry::Common::Utilities.config_opt('OTEL_EXPORTER_OTLP_LOGS_CERTIFICATE', 'OTEL_EXPORTER_OTLP_CERTIFICATE'),
                         client_certificate_file: OpenTelemetry::Common::Utilities.config_opt('OTEL_EXPORTER_OTLP_LOGS_CLIENT_CERTIFICATE', 'OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE'),
                         client_key_file: OpenTelemetry::Common::Utilities.config_opt('OTEL_EXPORTER_OTLP_LOGS_CLIENT_KEY', 'OTEL_EXPORTER_OTLP_CLIENT_KEY'),
                         ssl_verify_mode: nil,
                         headers: OpenTelemetry::Common::Utilities.config_opt('OTEL_EXPORTER_OTLP_LOGS_HEADERS', 'OTEL_EXPORTER_OTLP_HEADERS', default: {}),
                         compression: OpenTelemetry::Common::Utilities.config_opt('OTEL_EXPORTER_OTLP_LOGS_COMPRESSION', 'OTEL_EXPORTER_OTLP_COMPRESSION', default: 'gzip'),
                         timeout: OpenTelemetry::Common::Utilities.config_opt('OTEL_EXPORTER_OTLP_LOGS_TIMEOUT', 'OTEL_EXPORTER_OTLP_TIMEOUT', default: 10))
            raise ArgumentError, "invalid url for OTLP::Logs::LogsExporter #{endpoint}" unless OpenTelemetry::Common::Utilities.valid_url?(endpoint)
            raise ArgumentError, "unsupported compression key #{compression}" unless compression.nil? || %w[gzip none].include?(compression)

            @uri = if endpoint == ENV['OTEL_EXPORTER_OTLP_ENDPOINT'] || endpoint == ENV['OTEL_EXPORTER_OTLP_LOGS_ENDPOINT']
                     endpoint += '/' unless endpoint.end_with?('/')
                     URI.join(endpoint, 'v1/logs')
                   else
                     URI(endpoint)
                   end
            @client = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(uri: @uri, type: 'log', useragent: DEFAULT_USER_AGENT, certificate_file: certificate_file, client_certificate_file: client_certificate_file, client_key_file: client_key_file, ssl_verify_mode: ssl_verify_mode, headers: headers, compression: compression, timeout: timeout)
            @http = @client.instance_variable_get(:@http)

            @path = @uri.path
            @headers = headers
            @timeout = timeout.to_f
            @compression = compression
            @shutdown = false
          end

          # Called to export sampled {OpenTelemetry::SDK::Logs::LogRecordData} structs.
          #
          # @param [Enumerable<OpenTelemetry::SDK::Logs::LogRecordData>] log_record_data the
          #   list of recorded {OpenTelemetry::SDK::Logs::LogRecordData} structs to be
          #   exported.
          # @param [optional Numeric] timeout An optional timeout in seconds.
          # @return [Integer] the result of the export.
          def export(log_record_data, timeout: nil)
            OpenTelemetry.logger.error('Logs Exporter tried to export, but it has already shut down') if @shutdown
            return OpenTelemetry::SDK::Logs::Export::FAILURE if @shutdown

            result = @client.send_bytes(encode(log_record_data), timeout: timeout)
            log_status(result.response.body) unless result.response.nil?
            result.success ? OpenTelemetry::SDK::Logs::Export::SUCCESS : OpenTelemetry::SDK::Logs::Export::FAILURE
          end

          # Called when {OpenTelemetry::SDK::Logs::LoggerProvider#force_flush} is called, if
          # this exporter is registered to a {OpenTelemetry::SDK::Logs::LoggerProvider}
          # object.
          #
          # @param [optional Numeric] timeout An optional timeout in seconds.
          def force_flush(timeout: nil)
            OpenTelemetry::SDK::Logs::Export::SUCCESS
          end

          # Called when {OpenTelemetry::SDK::Logs::LoggerProvider#shutdown} is called, if
          # this exporter is registered to a {OpenTelemetry::SDK::Logs::LoggerProvider}
          # object.
          #
          # @param [optional Numeric] timeout An optional timeout in seconds.
          def shutdown(timeout: nil)
            @shutdown = true
            @client.finish if @client.started?
            OpenTelemetry::SDK::Logs::Export::SUCCESS
          end

          private

          def log_status(body)
            status = Google::Rpc::Status.decode(body)
            pool = ::Google::Protobuf::DescriptorPool.generated_pool
            details = status.details.filter_map do |detail|
              klass = pool.lookup(detail.type_name).msgclass
              detail.unpack(klass) if klass
            end
            OpenTelemetry.handle_error(message: "OTLP logs exporter received rpc.Status{message=#{status.message}, details=#{details}}")
          rescue StandardError => e
            OpenTelemetry.handle_error(exception: e, message: 'unexpected error decoding rpc.Status in OTLP::Exporter#log_status')
          end

          def encode(log_record_data) # rubocop:disable Metrics/MethodLength, Metrics/CyclomaticComplexity
            Opentelemetry::Proto::Collector::Logs::V1::ExportLogsServiceRequest.encode(
              Opentelemetry::Proto::Collector::Logs::V1::ExportLogsServiceRequest.new(
                resource_logs: log_record_data
                               .group_by(&:resource)
                               .map do |resource, log_record_datas|
                                 Opentelemetry::Proto::Logs::V1::ResourceLogs.new(
                                   resource: Opentelemetry::Proto::Resource::V1::Resource.new(
                                     attributes: resource.attribute_enumerator.map { |key, value| as_otlp_key_value(key, value) }
                                   ),
                                   scope_logs: log_record_datas
                                               .group_by(&:instrumentation_scope)
                                               .map do |il, lrd|
                                                 Opentelemetry::Proto::Logs::V1::ScopeLogs.new(
                                                   scope: Opentelemetry::Proto::Common::V1::InstrumentationScope.new(
                                                     name: il.name,
                                                     version: il.version
                                                   ),
                                                   log_records: lrd.map { |lr| as_otlp_log_record(lr) }
                                                 )
                                               end
                                 )
                               end
              )
            )
          rescue StandardError => e
            OpenTelemetry.handle_error(exception: e, message: 'unexpected error in OTLP::Exporter#encode')
            nil
          end

          def as_otlp_log_record(log_record_data)
            Opentelemetry::Proto::Logs::V1::LogRecord.new(
              time_unix_nano: log_record_data.timestamp,
              observed_time_unix_nano: log_record_data.observed_timestamp,
              severity_number: log_record_data.severity_number,
              severity_text: log_record_data.severity_text,
              body: as_otlp_any_value(log_record_data.body),
              attributes: log_record_data.attributes&.map { |k, v| as_otlp_key_value(k, v) },
              dropped_attributes_count: log_record_data.total_recorded_attributes - log_record_data.attributes&.size.to_i,
              event_name: log_record_data.event_name,
              flags: log_record_data.trace_flags.instance_variable_get(:@flags),
              trace_id: log_record_data.trace_id,
              span_id: log_record_data.span_id
            )
          end

          def as_otlp_key_value(key, value)
            Opentelemetry::Proto::Common::V1::KeyValue.new(key: key, value: as_otlp_any_value(value))
          rescue Encoding::UndefinedConversionError => e
            encoded_value = value.encode('UTF-8', invalid: :replace, undef: :replace, replace: '�')
            OpenTelemetry.handle_error(exception: e, message: "encoding error for key #{key} and value #{encoded_value}")
            Opentelemetry::Proto::Common::V1::KeyValue.new(key: key, value: as_otlp_any_value('Encoding Error'))
          end

          def as_otlp_any_value(value) # rubocop:disable Metrics/CyclomaticComplexity
            result = Opentelemetry::Proto::Common::V1::AnyValue.new
            case value
            when String
              result.string_value = value
            when Integer
              result.int_value = value
            when Float
              result.double_value = value
            when true, false
              result.bool_value = value
            when Array
              values = value.map { |element| as_otlp_any_value(element) }
              result.array_value = Opentelemetry::Proto::Common::V1::ArrayValue.new(values: values)
            when Hash
              values = value.map { |k, v| as_otlp_key_value(k, v) }
              result.kvlist_value = Opentelemetry::Proto::Common::V1::KeyValueList.new(values: values)
            end
            result
          end
        end
      end
    end
  end
end
