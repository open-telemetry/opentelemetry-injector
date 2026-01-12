#!/usr/bin/env sh

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# Add dummy no-op OTel auto instrumentation agents which actually do nothing but make the file check in the injector
# pass, so we can test whether NODE_OPTIONS, JAVA_TOOL_OPTIONS, etc. have been modfied as expected.

mkdir -p /usr/lib/opentelemetry/dotnet/glibc/linux-x64
mkdir -p /usr/lib/opentelemetry/dotnet/glibc/linux-arm64
mkdir -p /usr/lib/opentelemetry/dotnet/musl/linux-musl-x64
mkdir -p /usr/lib/opentelemetry/dotnet/musl/linux-musl-arm64
touch /usr/lib/opentelemetry/dotnet/glibc/linux-x64/OpenTelemetry.AutoInstrumentation.Native.so
touch /usr/lib/opentelemetry/dotnet/glibc/linux-arm64/OpenTelemetry.AutoInstrumentation.Native.so
touch /usr/lib/opentelemetry/dotnet/musl/linux-musl-x64/OpenTelemetry.AutoInstrumentation.Native.so
touch /usr/lib/opentelemetry/dotnet/musl/linux-musl-arm64/OpenTelemetry.AutoInstrumentation.Native.so
mkdir -p /usr/lib/opentelemetry/dotnet/glibc/AdditionalDeps
mkdir -p /usr/lib/opentelemetry/dotnet/musl/AdditionalDeps
mkdir -p /usr/lib/opentelemetry/dotnet/glibc/store
mkdir -p /usr/lib/opentelemetry/dotnet/musl/store
mkdir -p /usr/lib/opentelemetry/dotnet/glibc/net
mkdir -p /usr/lib/opentelemetry/dotnet/musl/net
if [ -d no-op-startup-hook ]; then
  cp no-op-startup-hook/* /usr/lib/opentelemetry/dotnet/glibc/net/
  cp no-op-startup-hook/* /usr/lib/opentelemetry/dotnet/musl/net/
fi

# JVM
# Copy the no-op agent jar file that is created in injector-integration-tests/runtimes/jvm/Dockerfile
if [ -f no-op-agent/no-op-agent.jar ]; then
  mkdir -p /usr/lib/opentelemetry/jvm
  cp no-op-agent/no-op-agent.jar /usr/lib/opentelemetry/jvm/javaagent.jar
fi

# Node.js
# An empty file works fine as a no-op Node.js module.
mkdir -p /usr/lib/opentelemetry/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/build/src
touch /usr/lib/opentelemetry/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/build/src/register.js

# Provide instrumentation files also in three more locations, for testing configuration via
# /etc/opentelemetry/otelinject.conf/, OTEL_INJECTOR_CONFIG_FILE, and via environment variables
# NODEJS_AUTO_INSTRUMENTATION_AGENT_PATH and friends.
mkdir -p /path/from
cp -R /usr/lib/opentelemetry /path/from/config-file
cp -R /usr/lib/opentelemetry /path/from/environment-variable
cp -R /usr/lib/opentelemetry /path/from/config-file-custom-location
