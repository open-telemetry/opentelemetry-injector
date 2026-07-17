# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# No-op stand-in for the opentelemetry-auto-instrumentation gem entry point. It does nothing except
# record that it was loaded, so tests can verify the injector made Ruby require it via RUBYOPT.
$otel_injector_ruby_no_op_agent_has_been_loaded = true
