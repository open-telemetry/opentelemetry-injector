#!/usr/bin/env sh

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

echo "deliberately creating inaccessible OTel auto instrumentation dummy files"

# .NET
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
touch /__otel_auto_instrumentation/dotnet/glibc/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll
touch /__otel_auto_instrumentation/dotnet/musl/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll

# JVM
mkdir -p /__otel_auto_instrumentation/jvm && touch /__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar

# Node.js
mkdir -p /__otel_auto_instrumentation/node_js/node_modules/@opentelemetry-js/otel/instrument
touch /__otel_auto_instrumentation/node_js/node_modules/@opentelemetry-js/otel/instrument/index.js

# make all files inaccessible
chmod -R 600 /__otel_auto_instrumentation
