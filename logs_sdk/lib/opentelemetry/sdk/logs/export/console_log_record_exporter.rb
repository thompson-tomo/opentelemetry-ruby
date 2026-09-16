# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

module OpenTelemetry
  module SDK
    module Logs
      module Export
        # Outputs {LogRecordData} to the console.
        #
        # Potentially useful for exploratory purposes.
        class ConsoleLogRecordExporter
          def initialize
            @stopped = false
          end

          def export(log_records, timeout: nil)
            return OpenTelemetry::Logs::ExportStatus::FAILURE if @stopped

            Array(log_records).each { |s| pp s }

            OpenTelemetry::Logs::ExportStatus::SUCCESS
          end

          def force_flush(timeout: nil)
            OpenTelemetry::Logs::ExportStatus::SUCCESS
          end

          def shutdown(timeout: nil)
            @stopped = true
            OpenTelemetry::Logs::ExportStatus::SUCCESS
          end
        end
      end
    end
  end
end
