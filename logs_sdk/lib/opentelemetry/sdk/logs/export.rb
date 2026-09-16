# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

module OpenTelemetry
  module SDK
    module Logs
      # The Export module contains the built-in exporters and log record
      # processors for the OpenTelemetry reference implementation.
      module Export
      end
    end
  end
end

require_relative 'export/console_log_record_exporter'
require_relative 'export/in_memory_log_record_exporter'
require_relative 'export/simple_log_record_processor'
require_relative 'export/batch_log_record_processor'
