#!/usr/bin/env sh

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# Add dummy no-op OTel auto instrumentation agents which actually do nothing but make the file check in the injector
# pass, so we can test whether NODE_OPTIONS, JAVA_TOOL_OPTIONS, etc. have been modfied as expected.

# Node.js
# An empty file works fine as a no-op Node.js module.
mkdir -p /__otel_auto_instrumentation/node_js/node_modules/@opentelemetry-js/otel/instrument
touch /__otel_auto_instrumentation/node_js/node_modules/@opentelemetry-js/otel/instrument/index.js

# JVM
# Copy the no-op agent jar file that is created in test/docker/Dockerfile-jvm
if [ -f no-op-agent/no-op-agent.jar ]; then
  mkdir -p /__otel_auto_instrumentation/jvm
  cp no-op-agent/no-op-agent.jar /__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar
fi
