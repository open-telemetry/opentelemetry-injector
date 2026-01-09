#!/usr/bin/env sh

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# Add dummy no-op OTel auto instrumentation agents which actually do nothing but make the file check in the injector
# pass, so we can test whether NODE_OPTIONS, JAVA_TOOL_OPTIONS, etc. have been modfied as expected.

mkdir -p /__otel_auto_instrumentation/dotnet/glibc/linux-x64
mkdir -p /__otel_auto_instrumentation/dotnet/glibc/linux-arm64
mkdir -p /__otel_auto_instrumentation/dotnet/musl/linux-musl-x64
mkdir -p /__otel_auto_instrumentation/dotnet/musl/linux-musl-arm64
touch /__otel_auto_instrumentation/dotnet/glibc/linux-x64/OpenTelemetry.AutoInstrumentation.Native.so
touch /__otel_auto_instrumentation/dotnet/glibc/linux-arm64/OpenTelemetry.AutoInstrumentation.Native.so
touch /__otel_auto_instrumentation/dotnet/musl/linux-musl-x64/OpenTelemetry.AutoInstrumentation.Native.so
touch /__otel_auto_instrumentation/dotnet/musl/linux-musl-arm64/OpenTelemetry.AutoInstrumentation.Native.so
mkdir -p /__otel_auto_instrumentation/dotnet/glibc/AdditionalDeps
mkdir -p /__otel_auto_instrumentation/dotnet/musl/AdditionalDeps
mkdir -p /__otel_auto_instrumentation/dotnet/glibc/store
mkdir -p /__otel_auto_instrumentation/dotnet/musl/store
mkdir -p /__otel_auto_instrumentation/dotnet/glibc/net
mkdir -p /__otel_auto_instrumentation/dotnet/musl/net
if [ -d no-op-startup-hook ]; then
  cp no-op-startup-hook/* /__otel_auto_instrumentation/dotnet/glibc/net/
  cp no-op-startup-hook/* /__otel_auto_instrumentation/dotnet/musl/net/
fi

# JVM
# Copy the no-op agent jar file that is created in test/docker/Dockerfile-jvm
if [ -f no-op-agent/no-op-agent.jar ]; then
  mkdir -p /__otel_auto_instrumentation/jvm
  cp no-op-agent/no-op-agent.jar /__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar
fi

# Node.js
# An empty file works fine as a no-op Node.js module.
mkdir -p /__otel_auto_instrumentation/node_js/node_modules/@opentelemetry-js/otel/instrument
touch /__otel_auto_instrumentation/node_js/node_modules/@opentelemetry-js/otel/instrument/index.js

# Provide instrumentation files also in three more locations, for testing configuration via
# /etc/opentelemetry/otelinject.conf/, OTEL_INJECTOR_CONFIG_FILE, and via environment variables
# NODEJS_AUTO_INSTRUMENTATION_AGENT_PATH and friends.
mkdir -p /path/from
cp -R /__otel_auto_instrumentation /path/from/config-file
cp -R /__otel_auto_instrumentation /path/from/environment-variable
cp -R /__otel_auto_instrumentation /path/from/config-file-custom-location
