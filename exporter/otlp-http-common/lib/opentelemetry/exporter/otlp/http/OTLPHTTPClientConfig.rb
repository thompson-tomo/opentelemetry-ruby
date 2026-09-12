# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

module OpenTelemetry
  module Exporter
    module OTLP
      module HTTP
        class OTLPHTTPClientConfig
          attr_reader :certificate_file,
                      :client_certificate_file,
                      :client_key_file,
                      :ssl_verify_mode,
                      :endpoint

          def initialize(
            certificate_file: nil,
            client_certificate_file: nil,
            client_key_file: nil,
            ssl_verify_mode: nil,
            endpoint: nil
          )
            @certificate_file = certificate_file
            @client_certificate_file = client_certificate_file
            @client_key_file = client_key_file
            @ssl_verify_mode = ssl_verify_mode
            @endpoint = endpoint
          end
        end
      end
    end
  end
end
