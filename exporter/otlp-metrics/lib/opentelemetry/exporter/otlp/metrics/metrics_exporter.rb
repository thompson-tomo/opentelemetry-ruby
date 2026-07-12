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
require 'opentelemetry/proto/metrics/v1/metrics_pb'
require 'opentelemetry/proto/collector/metrics/v1/metrics_service_pb'

require 'opentelemetry/metrics'
require 'opentelemetry/sdk/metrics'

require_relative 'util'

module OpenTelemetry
  module Exporter
    module OTLP
      module Metrics
        # An OpenTelemetry metrics exporter that sends metrics over HTTP as Protobuf encoded OTLP ExportMetricsServiceRequest.
        class MetricsExporter < ::OpenTelemetry::SDK::Metrics::Export::MetricReader
          include Util

          attr_reader :metric_snapshots

          def initialize(endpoint: OpenTelemetry::Common::Utilities.config_opt('OTEL_EXPORTER_OTLP_METRICS_ENDPOINT', 'OTEL_EXPORTER_OTLP_ENDPOINT', default: 'http://localhost:4318/v1/metrics'),
                         certificate_file: OpenTelemetry::Common::Utilities.config_opt('OTEL_EXPORTER_OTLP_METRICS_CERTIFICATE', 'OTEL_EXPORTER_OTLP_CERTIFICATE'),
                         client_certificate_file: OpenTelemetry::Common::Utilities.config_opt('OTEL_EXPORTER_OTLP_METRICS_CLIENT_CERTIFICATE', 'OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE'),
                         client_key_file: OpenTelemetry::Common::Utilities.config_opt('OTEL_EXPORTER_OTLP_METRICS_CLIENT_KEY', 'OTEL_EXPORTER_OTLP_CLIENT_KEY'),
                         ssl_verify_mode: nil,
                         headers: OpenTelemetry::Common::Utilities.config_opt('OTEL_EXPORTER_OTLP_METRICS_HEADERS', 'OTEL_EXPORTER_OTLP_HEADERS', default: {}),
                         compression: OpenTelemetry::Common::Utilities.config_opt('OTEL_EXPORTER_OTLP_METRICS_COMPRESSION', 'OTEL_EXPORTER_OTLP_COMPRESSION', default: 'gzip'),
                         timeout: OpenTelemetry::Common::Utilities.config_opt('OTEL_EXPORTER_OTLP_METRICS_TIMEOUT', 'OTEL_EXPORTER_OTLP_TIMEOUT', default: 10),
                         aggregation_cardinality_limit: nil)
            raise ArgumentError, "invalid url for OTLP::MetricsExporter #{endpoint}" unless OpenTelemetry::Common::Utilities.valid_url?(endpoint)
            raise ArgumentError, "unsupported compression key #{compression}" unless compression.nil? || %w[gzip none].include?(compression)

            # create the MetricStore object
            super(aggregation_cardinality_limit: aggregation_cardinality_limit)

            @uri = if endpoint == ENV['OTEL_EXPORTER_OTLP_ENDPOINT']
                     endpoint += '/' unless endpoint.end_with?('/')
                     URI.join(endpoint, 'v1/metrics')
                   else
                     URI(endpoint)
                   end

            @client = OpenTelemetry::Exporter::OTLP::Common::OTLPClient.new(uri: @uri, type: 'metrics', useragent: DEFAULT_USER_AGENT, certificate_file: certificate_file, client_certificate_file: client_certificate_file, client_key_file: client_key_file, ssl_verify_mode: ssl_verify_mode, headers: headers, compression: compression, timeout: timeout)
            @http = @client.instance_variable_get(:@http)

            @path = @uri.path
            @headers = headers
            @timeout = timeout.to_f
            @compression = compression
            @mutex = Mutex.new
            @shutdown = false
          end

          # consolidate the metrics data into the form of MetricData
          #
          # return MetricData
          def pull
            export(collect)
          end

          # metrics Array[MetricData]
          def export(metrics, timeout: nil)
            @mutex.synchronize do
              result = @client.send_bytes(encode(metrics), timeout: timeout)
              log_status(result.response.body) unless result.response.nil?
              result.success ? OpenTelemetry::SDK::Metrics::Export::SUCCESS : OpenTelemetry::SDK::Metrics::Export::FAILURE
            end
          end

          def encode(metrics_data)
            Opentelemetry::Proto::Collector::Metrics::V1::ExportMetricsServiceRequest.encode(
              Opentelemetry::Proto::Collector::Metrics::V1::ExportMetricsServiceRequest.new(
                resource_metrics: metrics_data
                                  .group_by(&:resource)
                                  .map do |resource, scope_metrics|
                                    Opentelemetry::Proto::Metrics::V1::ResourceMetrics.new(
                                      resource: Opentelemetry::Proto::Resource::V1::Resource.new(
                                        attributes: resource.attribute_enumerator.map { |key, value| as_otlp_key_value(key, value) }
                                      ),
                                      scope_metrics: scope_metrics
                                                     .group_by(&:instrumentation_scope)
                                                     .map do |instrumentation_scope, metrics|
                                                       Opentelemetry::Proto::Metrics::V1::ScopeMetrics.new(
                                                         scope: Opentelemetry::Proto::Common::V1::InstrumentationScope.new(
                                                           name: instrumentation_scope.name,
                                                           version: instrumentation_scope.version
                                                         ),
                                                         metrics: metrics.map { |sd| as_otlp_metrics(sd) }
                                                       )
                                                     end
                                    )
                                  end
              )
            )
          rescue StandardError => e
            OpenTelemetry.handle_error(exception: e, message: 'unexpected error in OTLP::MetricsExporter#encode')
            nil
          end

          # metrics_pb has following type of data: :gauge, :sum, :histogram, :exponential_histogram, :summary
          # current metric sdk only implements instrument: :counter -> :sum, :histogram -> :histogram, :gauge -> :gauge
          #
          # metrics [MetricData]
          def as_otlp_metrics(metrics)
            case metrics.instrument_kind
            when :observable_gauge, :gauge
              Opentelemetry::Proto::Metrics::V1::Metric.new(
                name: metrics.name,
                description: metrics.description,
                unit: metrics.unit,
                gauge: Opentelemetry::Proto::Metrics::V1::Gauge.new(
                  data_points: metrics.data_points.map do |ndp|
                    number_data_point(ndp)
                  end
                )
              )

            when :counter, :up_down_counter, :observable_counter, :observable_up_down_counter
              Opentelemetry::Proto::Metrics::V1::Metric.new(
                name: metrics.name,
                description: metrics.description,
                unit: metrics.unit,
                sum: Opentelemetry::Proto::Metrics::V1::Sum.new(
                  aggregation_temporality: as_otlp_aggregation_temporality(metrics.aggregation_temporality),
                  data_points: metrics.data_points.map do |ndp|
                    number_data_point(ndp)
                  end,
                  is_monotonic: metrics.is_monotonic
                )
              )

            when :histogram
              histogram_data_point(metrics)

            end
          end

          def as_otlp_aggregation_temporality(type)
            case type
            when :delta then Opentelemetry::Proto::Metrics::V1::AggregationTemporality::AGGREGATION_TEMPORALITY_DELTA
            when :cumulative then Opentelemetry::Proto::Metrics::V1::AggregationTemporality::AGGREGATION_TEMPORALITY_CUMULATIVE
            else Opentelemetry::Proto::Metrics::V1::AggregationTemporality::AGGREGATION_TEMPORALITY_UNSPECIFIED
            end
          end

          def histogram_data_point(metrics)
            return if metrics.data_points.empty?

            if metrics.data_points.first.instance_of?(OpenTelemetry::SDK::Metrics::Aggregation::ExponentialHistogramDataPoint)
              Opentelemetry::Proto::Metrics::V1::Metric.new(
                name: metrics.name,
                description: metrics.description,
                unit: metrics.unit,
                exponential_histogram: Opentelemetry::Proto::Metrics::V1::ExponentialHistogram.new(
                  aggregation_temporality: as_otlp_aggregation_temporality(metrics.aggregation_temporality),
                  data_points: metrics.data_points.map do |ehdp|
                    exponential_histogram_data_point(ehdp)
                  end
                )
              )
            elsif metrics.data_points.first.instance_of?(OpenTelemetry::SDK::Metrics::Aggregation::HistogramDataPoint)
              Opentelemetry::Proto::Metrics::V1::Metric.new(
                name: metrics.name,
                description: metrics.description,
                unit: metrics.unit,
                histogram: Opentelemetry::Proto::Metrics::V1::Histogram.new(
                  aggregation_temporality: as_otlp_aggregation_temporality(metrics.aggregation_temporality),
                  data_points: metrics.data_points.map do |hdp|
                    explicit_histogram_data_point(hdp)
                  end
                )
              )
            end
          end

          def explicit_histogram_data_point(hdp)
            Opentelemetry::Proto::Metrics::V1::HistogramDataPoint.new(
              attributes: hdp.attributes.map { |k, v| as_otlp_key_value(k, v) },
              start_time_unix_nano: hdp.start_time_unix_nano,
              time_unix_nano: hdp.time_unix_nano,
              count: hdp.count,
              sum: hdp.sum,
              bucket_counts: hdp.bucket_counts,
              explicit_bounds: hdp.explicit_bounds,
              exemplars: as_otlp_exemplars(hdp.exemplars),
              min: hdp.min,
              max: hdp.max
            )
          end

          def exponential_histogram_data_point(ehdp)
            Opentelemetry::Proto::Metrics::V1::ExponentialHistogramDataPoint.new(
              attributes: ehdp.attributes.map { |k, v| as_otlp_key_value(k, v) },
              start_time_unix_nano: ehdp.start_time_unix_nano,
              time_unix_nano: ehdp.time_unix_nano,
              count: ehdp.count,
              sum: ehdp.sum,
              scale: ehdp.scale,
              zero_count: ehdp.zero_count,
              positive: Opentelemetry::Proto::Metrics::V1::ExponentialHistogramDataPoint::Buckets.new(
                offset: ehdp.positive.offset,
                bucket_counts: ehdp.positive.counts
              ),
              negative: Opentelemetry::Proto::Metrics::V1::ExponentialHistogramDataPoint::Buckets.new(
                offset: ehdp.negative.offset,
                bucket_counts: ehdp.negative.counts
              ),
              flags: ehdp.flags,
              exemplars: as_otlp_exemplars(ehdp.exemplars),
              min: ehdp.min,
              max: ehdp.max,
              zero_threshold: ehdp.zero_threshold
            )
          end

          def number_data_point(ndp)
            args = {
              attributes: ndp.attributes.map { |k, v| as_otlp_key_value(k, v) },
              start_time_unix_nano: ndp.start_time_unix_nano,
              time_unix_nano: ndp.time_unix_nano,
              exemplars: as_otlp_exemplars(ndp.exemplars)
            }

            if ndp.value.is_a?(Float)
              args[:as_double] = ndp.value
            else
              args[:as_int] = ndp.value
            end

            Opentelemetry::Proto::Metrics::V1::NumberDataPoint.new(**args)
          end

          def as_otlp_exemplars(exemplars)
            exemplars&.map { |ex| as_otlp_exemplar(ex) } || []
          end

          def as_otlp_exemplar(exemplar)
            args = {
              time_unix_nano: exemplar.time_unix_nano,
              span_id: exemplar.span_id,
              trace_id: exemplar.trace_id
            }

            # Add filtered_attributes if present
            args[:filtered_attributes] = exemplar.filtered_attributes.map { |k, v| as_otlp_key_value(k, v) } if exemplar.filtered_attributes

            # Set value based on type
            if exemplar.value.is_a?(Float)
              args[:as_double] = exemplar.value
            else
              args[:as_int] = exemplar.value
            end

            Opentelemetry::Proto::Metrics::V1::Exemplar.new(**args)
          end

          # may not need this
          def reset
            OpenTelemetry::SDK::Metrics::Export::SUCCESS
          end

          def force_flush(timeout: nil)
            OpenTelemetry::SDK::Metrics::Export::SUCCESS
          end

          def shutdown(timeout: nil)
            @shutdown = true
            OpenTelemetry::SDK::Metrics::Export::SUCCESS
          end
        end
      end
    end
  end
end
