#!/usr/bin/env sh

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

echo "deliberately creating inaccessible OTel auto instrumentation dummy files"
mkdir -p /__otel_auto_instrumentation/node_js/node_modules/@opentelemetry-js/otel/instrument
touch /__otel_auto_instrumentation/node_js/node_modules/@opentelemetry-js/otel/instrument/index.js
mkdir -p /__otel_auto_instrumentation/jvm && touch /__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar
chmod -R 600 /__otel_auto_instrumentation

