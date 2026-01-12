#!/usr/bin/env sh

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

echo "deliberately creating inaccessible OTel auto instrumentation dummy files"

# .NET
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
touch /usr/lib/opentelemetry/dotnet/glibc/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll
touch /usr/lib/opentelemetry/dotnet/musl/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll

# JVM
mkdir -p /usr/lib/opentelemetry/jvm && touch /usr/lib/opentelemetry/jvm/javaagent.jar

# Node.js
mkdir -p /usr/lib/opentelemetry/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/build/src
touch /usr/lib/opentelemetry/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/build/src/register.js

# make all files inaccessible
chmod -R 600 /usr/lib/opentelemetry
