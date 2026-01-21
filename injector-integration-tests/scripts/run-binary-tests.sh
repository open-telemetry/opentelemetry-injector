#!/usr/bin/env bash

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# Runs binary validation tests for the injector library.
# These tests validate ELF binary properties (like no weak symbols) using readelf.

set -eu

cd "$(dirname "${BASH_SOURCE[0]}")"/../..

if [ -z "${ARCH:-}" ]; then
  ARCH=arm64
fi
if [ "$ARCH" = arm64 ]; then
  docker_platform=linux/arm64
  expected_cpu_architecture=aarch64
  injector_binary=libotelinject_arm64.so
elif [ "$ARCH" = amd64 ]; then
  docker_platform=linux/amd64
  expected_cpu_architecture=x86_64
  injector_binary=libotelinject_amd64.so
else
  echo "The architecture $ARCH is not supported."
  exit 1
fi

image_name=otel-injector-binary-validation-$ARCH
docker rmi -f "$image_name" 2> /dev/null || true

set -x
docker build \
  --platform "$docker_platform" \
  --build-arg "injector_binary=$injector_binary" \
  . \
  -f "injector-integration-tests/binary/Dockerfile" \
  -t "$image_name"
{ set +x; } 2> /dev/null

set -x
docker run \
  --rm \
  --platform "$docker_platform" \
  --env EXPECTED_CPU_ARCHITECTURE="$expected_cpu_architecture" \
  --env VERBOSE="${VERBOSE:-}" \
  "$image_name"
{ set +x; } 2> /dev/null
