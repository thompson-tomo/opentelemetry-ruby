# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require 'opentelemetry/common'
require 'opentelemetry/exporter/otlp_common'
require 'opentelemetry/sdk'
require 'net/http'
require 'zlib'

require 'google/rpc/status_pb'

require 'opentelemetry/proto/common/v1/common_pb'
require 'opentelemetry/proto/resource/v1/resource_pb'
require 'opentelemetry/proto/trace/v1/trace_pb'
require 'opentelemetry/proto/collector/trace/v1/trace_service_pb'

module OpenTelemetry
  module Exporter
    module OTLP
      # An OpenTelemetry trace exporter that sends spans over HTTP as Protobuf encoded OTLP ExportTraceServiceRequests.
      class Exporter # rubocop:disable Metrics/ClassLength
        SUCCESS = OpenTelemetry::SDK::Trace::Export::SUCCESS
        FAILURE = OpenTelemetry::SDK::Trace::Export::FAILURE
        private_constant(:SUCCESS, :FAILURE)

        # Default timeouts in seconds.
        KEEP_ALIVE_TIMEOUT = 30
        RETRY_COUNT = 5
        private_constant(:KEEP_ALIVE_TIMEOUT, :RETRY_COUNT)

        ERROR_MESSAGE_INVALID_HEADERS = 'headers must be a String with comma-separated URL Encoded UTF-8 k=v pairs or a Hash'
        private_constant(:ERROR_MESSAGE_INVALID_HEADERS)

        DEFAULT_USER_AGENT = "OTel-OTLP-Exporter-Ruby/#{OpenTelemetry::Exporter::OTLP::VERSION} Ruby/#{RUBY_VERSION} (#{RUBY_PLATFORM}; #{RUBY_ENGINE}/#{RUBY_ENGINE_VERSION})".freeze

        # rubocop:disable Lint/DuplicateBranch
        def self.ssl_verify_mode
          if ENV.key?('OTEL_RUBY_EXPORTER_OTLP_SSL_VERIFY_PEER')
            OpenSSL::SSL::VERIFY_PEER
          elsif ENV.key?('OTEL_RUBY_EXPORTER_OTLP_SSL_VERIFY_NONE')
            OpenSSL::SSL::VERIFY_NONE
          else
            OpenSSL::SSL::VERIFY_PEER
          end
        end
        # rubocop:enable Lint/DuplicateBranch

        def initialize(endpoint: nil,
                       certificate_file: OpenTelemetry::Common::Utilities.config_opt('OTEL_EXPORTER_OTLP_TRACES_CERTIFICATE', 'OTEL_EXPORTER_OTLP_CERTIFICATE'),
                       client_certificate_file: OpenTelemetry::Common::Utilities.config_opt('OTEL_EXPORTER_OTLP_TRACES_CLIENT_CERTIFICATE', 'OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE'),
                       client_key_file: OpenTelemetry::Common::Utilities.config_opt('OTEL_EXPORTER_OTLP_TRACES_CLIENT_KEY', 'OTEL_EXPORTER_OTLP_CLIENT_KEY'),
                       ssl_verify_mode: Exporter.ssl_verify_mode,
                       headers: OpenTelemetry::Common::Utilities.config_opt('OTEL_EXPORTER_OTLP_TRACES_HEADERS', 'OTEL_EXPORTER_OTLP_HEADERS', default: {}),
                       compression: OpenTelemetry::Common::Utilities.config_opt('OTEL_EXPORTER_OTLP_TRACES_COMPRESSION', 'OTEL_EXPORTER_OTLP_COMPRESSION', default: 'gzip'),
                       timeout: OpenTelemetry::Common::Utilities.config_opt('OTEL_EXPORTER_OTLP_TRACES_TIMEOUT', 'OTEL_EXPORTER_OTLP_TIMEOUT', default: 10),
                       metrics_reporter: nil)
          @uri = prepare_endpoint(endpoint)

          raise ArgumentError, "unsupported compression key #{compression}" unless compression.nil? || %w[gzip none].include?(compression)

          @client = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(uri: @uri, type: 'traces', useragent: DEFAULT_USER_AGENT, certificate_file: certificate_file, client_certificate_file: client_certificate_file, client_key_file: client_key_file, ssl_verify_mode: ssl_verify_mode, headers: headers, compression: compression, timeout: timeout)
          @http = @client.instance_variable_get(:@http)

          @path = @uri.path
          @headers = headers
          @timeout = timeout.to_f
          @compression = compression
          @metrics_reporter = metrics_reporter || OpenTelemetry::SDK::Trace::Export::MetricsReporter
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

          result = @client.send_bytes(encode(span_data), timeout: timeout)
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

        # Builds span flags based on whether the parent span context is remote.
        # This follows the OTLP specification for span flags.
        def build_span_flags(parent_span_is_remote, base_flags)
          # Extract integer value from TraceFlags object if needed
          # Derive the low 8-bit W3C trace flags using the public API.
          base_flags_int =
            if base_flags.sampled?
              1
            else
              0
            end

          has_remote_mask = Opentelemetry::Proto::Trace::V1::SpanFlags::SPAN_FLAGS_CONTEXT_HAS_IS_REMOTE_MASK
          is_remote_mask = Opentelemetry::Proto::Trace::V1::SpanFlags::SPAN_FLAGS_CONTEXT_IS_REMOTE_MASK

          flags = base_flags_int | has_remote_mask
          flags |= is_remote_mask if parent_span_is_remote
          flags
        end

        # The around_request is a private method that provides an extension
        # point for the exporters network calls. The default behaviour
        # is to not trace these operations.
        #
        # An example use case would be to prepend a patch, or extend this class
        # and override this method's behaviour to explicitly trace the HTTP request.
        # This would allow you to trace your export pipeline.
        def around_request
          OpenTelemetry::Common::Utilities.untraced { yield } # rubocop:disable Style/ExplicitBlockArgument
        end

        def log_status(body)
          status = Google::Rpc::Status.decode(body)
          pool = ::Google::Protobuf::DescriptorPool.generated_pool
          details = status.details.filter_map do |detail|
            klass = pool.lookup(detail.type_name).msgclass
            detail.unpack(klass) if klass
          end
          OpenTelemetry.handle_error(message: "OTLP exporter received rpc.Status{message=#{status.message}, details=#{details}} for uri=#{@uri}")
        rescue StandardError => e
          OpenTelemetry.handle_error(exception: e, message: 'unexpected error decoding rpc.Status in OTLP::Exporter#log_status')
        end

        def encode(span_data) # rubocop:disable Metrics/MethodLength, Metrics/CyclomaticComplexity
          start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          Opentelemetry::Proto::Collector::Trace::V1::ExportTraceServiceRequest.encode(
            Opentelemetry::Proto::Collector::Trace::V1::ExportTraceServiceRequest.new(
              resource_spans: span_data
                              .group_by(&:resource)
                              .map do |resource, span_datas|
                                Opentelemetry::Proto::Trace::V1::ResourceSpans.new(
                                  resource: Opentelemetry::Proto::Resource::V1::Resource.new(
                                    attributes: resource.attribute_enumerator.map { |key, value| as_otlp_key_value(key, value) }
                                  ),
                                  scope_spans: span_datas
                                               .group_by(&:instrumentation_scope)
                                               .map do |il, sds|
                                                 Opentelemetry::Proto::Trace::V1::ScopeSpans.new(
                                                   scope: Opentelemetry::Proto::Common::V1::InstrumentationScope.new(
                                                     name: il.name,
                                                     version: il.version
                                                   ),
                                                   spans: sds.map { |sd| as_otlp_span(sd) }
                                                 )
                                               end
                                )
                              end
            )
          )
        rescue StandardError => e
          OpenTelemetry.handle_error(exception: e, message: 'unexpected error in OTLP::Exporter#encode')
          nil
        ensure
          stop = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          duration_ms = 1000.0 * (stop - start)
          @metrics_reporter.record_value('otel.otlp_exporter.encode_duration',
                                         value: duration_ms)
        end

        def as_otlp_span(span_data) # rubocop:disable Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          Opentelemetry::Proto::Trace::V1::Span.new(
            trace_id: span_data.trace_id,
            span_id: span_data.span_id,
            trace_state: span_data.tracestate.to_s,
            parent_span_id: span_data.parent_span_id == OpenTelemetry::Trace::INVALID_SPAN_ID ? nil : span_data.parent_span_id,
            name: span_data.name,
            kind: as_otlp_span_kind(span_data.kind),
            start_time_unix_nano: span_data.start_timestamp,
            end_time_unix_nano: span_data.end_timestamp,
            attributes: span_data.attributes&.map { |k, v| as_otlp_key_value(k, v) },
            dropped_attributes_count: span_data.total_recorded_attributes - span_data.attributes&.size.to_i,
            events: span_data.events&.map do |event|
              Opentelemetry::Proto::Trace::V1::Span::Event.new(
                time_unix_nano: event.timestamp,
                name: event.name,
                attributes: event.attributes&.map { |k, v| as_otlp_key_value(k, v) }
                # TODO: track dropped_attributes_count in Span#append_event
              )
            end,
            dropped_events_count: span_data.total_recorded_events - span_data.events&.size.to_i,
            links: span_data.links&.map do |link|
              Opentelemetry::Proto::Trace::V1::Span::Link.new(
                trace_id: link.span_context.trace_id,
                span_id: link.span_context.span_id,
                trace_state: link.span_context.tracestate.to_s,
                attributes: link.attributes&.map { |k, v| as_otlp_key_value(k, v) },
                # TODO: track dropped_attributes_count in Span#trim_links
                flags: build_span_flags(link.span_context.remote?, link.span_context.trace_flags)
              )
            end,
            dropped_links_count: span_data.total_recorded_links - span_data.links&.size.to_i,
            status: span_data.status&.then do |status|
              Opentelemetry::Proto::Trace::V1::Status.new(
                code: as_otlp_status_code(status.code),
                message: status.description
              )
            end,
            flags: build_span_flags(span_data.parent_span_is_remote, span_data.trace_flags)
          )
        end

        def as_otlp_status_code(code)
          case code
          when OpenTelemetry::Trace::Status::OK then Opentelemetry::Proto::Trace::V1::Status::StatusCode::STATUS_CODE_OK
          when OpenTelemetry::Trace::Status::ERROR then Opentelemetry::Proto::Trace::V1::Status::StatusCode::STATUS_CODE_ERROR
          else Opentelemetry::Proto::Trace::V1::Status::StatusCode::STATUS_CODE_UNSET
          end
        end

        def as_otlp_span_kind(kind)
          case kind
          when :internal then Opentelemetry::Proto::Trace::V1::Span::SpanKind::SPAN_KIND_INTERNAL
          when :server then Opentelemetry::Proto::Trace::V1::Span::SpanKind::SPAN_KIND_SERVER
          when :client then Opentelemetry::Proto::Trace::V1::Span::SpanKind::SPAN_KIND_CLIENT
          when :producer then Opentelemetry::Proto::Trace::V1::Span::SpanKind::SPAN_KIND_PRODUCER
          when :consumer then Opentelemetry::Proto::Trace::V1::Span::SpanKind::SPAN_KIND_CONSUMER
          else Opentelemetry::Proto::Trace::V1::Span::SpanKind::SPAN_KIND_UNSPECIFIED
          end
        end

        def as_otlp_key_value(key, value)
          Opentelemetry::Proto::Common::V1::KeyValue.new(key: key, value: as_otlp_any_value(value))
        rescue Encoding::UndefinedConversionError => e
          encoded_value = value.encode('UTF-8', invalid: :replace, undef: :replace, replace: '�')
          OpenTelemetry.handle_error(exception: e, message: "encoding error for key #{key} and value #{encoded_value}")
          Opentelemetry::Proto::Common::V1::KeyValue.new(key: key, value: as_otlp_any_value('Encoding Error'))
        end

        def as_otlp_any_value(value)
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
          end
          result
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
