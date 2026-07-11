# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require 'opentelemetry/common'
require 'net/http'
require 'zlib'

require 'google/rpc/status_pb'

module OpenTelemetry
  module Exporter
    module OTLP
      module Common
        # An OpenTelemetry log exporter that sends log records over HTTP as Protobuf encoded OTLP ExportLogsServiceRequests.
        class OTLPClient # rubocop:disable Metrics/ClassLength
          Result = Struct.new(:success, :response, keyword_init: true)

          # Default timeouts in seconds.
          KEEP_ALIVE_TIMEOUT = 30
          RETRY_COUNT = 5
          private_constant(:KEEP_ALIVE_TIMEOUT, :RETRY_COUNT)

          ERROR_MESSAGE_INVALID_HEADERS = 'headers must be a String with comma-separated URL Encoded UTF-8 k=v pairs or a Hash'
          private_constant(:ERROR_MESSAGE_INVALID_HEADERS)

          DEFAULT_USER_AGENT = "OTel-OTLP-Exporter-Ruby/#{OpenTelemetry::Exporter::OTLP::Logs::VERSION} Ruby/#{RUBY_VERSION} (#{RUBY_PLATFORM}; #{RUBY_ENGINE}/#{RUBY_ENGINE_VERSION})".freeze

          # rubocop:disable Lint/DuplicateBranch
          def self.ssl_verify_mode
            if ENV['OTEL_RUBY_EXPORTER_OTLP_SSL_VERIFY_PEER'] == 'true'
              OpenSSL::SSL::VERIFY_PEER
            elsif ENV['OTEL_RUBY_EXPORTER_OTLP_SSL_VERIFY_NONE'] == 'true'
              OpenSSL::SSL::VERIFY_NONE
            else
              OpenSSL::SSL::VERIFY_PEER
            end
          end
          # rubocop:enable Lint/DuplicateBranch

          def initialize(type, uri,
                         certificate_file: '',
                         client_certificate_file: '',
                         client_key_file: '',
                         headers: {},
                         compression: 'gzip',
                         timeout: 10)
            raise ArgumentError, "invalid url for OTLP::Logs::LogsExporter #{endpoint}" unless OpenTelemetry::Common::Utilities.valid_url?(endpoint)
            raise ArgumentError, "unsupported compression key #{compression}" unless compression.nil? || %w[gzip none].include?(compression)

            @uri = uri

            @http = http_connection(@uri, OTLPClient.ssl_verify_mode, certificate_file, client_certificate_file, client_key_file)

            @path = @uri.path
            @headers = prepare_headers(headers)
            @timeout = timeout.to_f
            @compression = compression
          end

          def send_bytes(bytes, timeout:) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
            return false if bytes.nil?

            request = Net::HTTP::Post.new(@path)
            if @compression == 'gzip'
              request.add_field('Content-Encoding', 'gzip')
              body = Zlib.gzip(bytes)
            else
              body = bytes
            end

            request.body = body
            request.add_field('Content-Type', 'application/x-protobuf')
            @headers.each { |key, value| request.add_field(key, value) }

            retry_count = 0
            timeout ||= @timeout
            start_time = OpenTelemetry::Common::Utilities.timeout_timestamp

            # rubocop:disable Lint/DuplicateBranch
            around_request do
              remaining_timeout = OpenTelemetry::Common::Utilities.maybe_timeout(timeout, start_time)
              return return Result.new(success: false) if remaining_timeout.zero?

              @http.open_timeout = remaining_timeout
              @http.read_timeout = remaining_timeout
              @http.write_timeout = remaining_timeout
              @http.start unless @http.started?
              response = @http.request(request)

              case response
              when Net::HTTPSuccess
                response.body # Read and discard body
                return Result.new(success: true)
              when Net::HTTPServiceUnavailable, Net::HTTPTooManyRequests
                response.body # Read and discard body
                handle_http_error(response)
                redo if backoff?(retry_after: response['Retry-After'], retry_count: retry_count += 1)
                return Result.new(success: false)
              when Net::HTTPRequestTimeOut, Net::HTTPGatewayTimeOut, Net::HTTPBadGateway
                response.body # Read and discard body
                handle_http_error(response)
                redo if backoff?(retry_count: retry_count += 1)
                return Result.new(success: false)
              when Net::HTTPNotFound
                handle_http_error(response)
                return Result.new(success: false)
              when Net::HTTPBadRequest, Net::HTTPClientError, Net::HTTPServerError
                return Result.new(success: false, response)
              when Net::HTTPRedirection
                @http.finish
                handle_redirect(response['location'])
                redo if backoff?(retry_after: 0, retry_count: retry_count += 1)
              else
                @http.finish
                handle_http_error(response)
                return Result.new(success: false)
              end
            rescue Net::OpenTimeout, Net::ReadTimeout => e
              OpenTelemetry.handle_error(exception: e)
              retry if backoff?(retry_count: retry_count += 1)
              return false
            rescue OpenSSL::SSL::SSLError => e
              OpenTelemetry.handle_error(exception: e)
              retry if backoff?(retry_count: retry_count += 1)
              return false
            rescue SocketError => e
              OpenTelemetry.handle_error(exception: e)
              retry if backoff?(retry_count: retry_count += 1)
              return Result.new(success: false)
            rescue SystemCallError => e
              retry if backoff?(retry_count: retry_count += 1)
              OpenTelemetry.handle_error(exception: e)
              return Result.new(success: false)
            rescue EOFError => e
              OpenTelemetry.handle_error(exception: e)
              retry if backoff?(retry_count: retry_count += 1)
              return Result.new(success: false)
            rescue Zlib::DataError => e
              OpenTelemetry.handle_error(exception: e)
              retry if backoff?(retry_count: retry_count += 1)
              return Result.new(success: false)
            rescue StandardError => e
              OpenTelemetry.handle_error(exception: e, message: 'unexpected error in OTLP::Exporter#send_bytes')
              return Result.new(success: false)
            end
            # rubocop:enable Lint/DuplicateBranch
          ensure
            # Reset timeouts to defaults for the next call.
            @http.open_timeout = @timeout
            @http.read_timeout = @timeout
            @http.write_timeout = @timeout
          end

          def finish
            @http.finish
          end

          def started?
            @http.started?
          end

          private

          def handle_http_error(response)
            OpenTelemetry.handle_error(message: "OTLP logs exporter received #{response.class.name}, http.code=#{response.code}, for uri: '#{@path}'")
          end

          def http_connection(uri, ssl_verify_mode, certificate_file, client_certificate_file, client_key_file)
            http = Net::HTTP.new(uri.hostname, uri.port)
            http.use_ssl = uri.scheme == 'https'
            http.verify_mode = ssl_verify_mode
            http.ca_file = certificate_file unless certificate_file.nil?
            http.cert = OpenSSL::X509::Certificate.new(File.read(client_certificate_file)) unless client_certificate_file.nil?
            http.key = OpenSSL::PKey::RSA.new(File.read(client_key_file)) unless client_key_file.nil?
            http.keep_alive_timeout = KEEP_ALIVE_TIMEOUT
            http
          end

          # The around_request is a private method that provides an extension
          # point for the exporters network calls. The default behaviour
          # is to not record these operations.
          #
          # An example use case would be to prepend a patch, or extend this class
          # and override this method's behaviour to explicitly record the HTTP request.
          # This would allow you to create log records for your export pipeline.
          def around_request
            OpenTelemetry::Common::Utilities.untraced { yield } # rubocop:disable Style/ExplicitBlockArgument
          end

          def handle_redirect(location)
            # TODO: figure out destination and reinitialize @http and @path
          end

          def backoff?(retry_count:, retry_after: nil) # rubocop:disable Metrics/CyclomaticComplexity
            return false if retry_count > RETRY_COUNT

            sleep_interval = nil
            unless retry_after.nil?
              sleep_interval =
                Integer(retry_after, exception: false)
              sleep_interval ||=
                begin
                  Time.httpdate(retry_after) - Time.now
                rescue # rubocop:disable Style/RescueStandardError
                  nil
                end
              sleep_interval = nil unless sleep_interval&.positive?
            end
            sleep_interval ||= rand(2**retry_count)

            sleep(sleep_interval)
            true
          end

          def prepare_headers(config_headers)
            headers = case config_headers
                      when String then parse_headers(config_headers)
                      when Hash then config_headers.dup
                      else
                        raise ArgumentError, ERROR_MESSAGE_INVALID_HEADERS
                      end

            headers['User-Agent'] = "#{headers.fetch('User-Agent', '')} #{DEFAULT_USER_AGENT}".strip

            headers
          end

          def parse_headers(raw)
            entries = raw.split(',')
            raise ArgumentError, ERROR_MESSAGE_INVALID_HEADERS if entries.empty?

            entries.each_with_object({}) do |entry, headers|
              k, v = entry.split('=', 2).map { |part| URI.decode_uri_component part }
              begin
                k = k.to_s.strip
                v = v.to_s.strip
              rescue Encoding::CompatibilityError
                raise ArgumentError, ERROR_MESSAGE_INVALID_HEADERS
              rescue ArgumentError => e
                raise e, ERROR_MESSAGE_INVALID_HEADERS
              end
              raise ArgumentError, ERROR_MESSAGE_INVALID_HEADERS if k.empty? || v.empty?

              headers[k] = v
            end
          end
        end
      end
    end
  end
end
