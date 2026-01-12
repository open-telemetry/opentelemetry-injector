#!/usr/bin/env bash

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

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

if [ -z "${LIBC:-}" ]; then
  LIBC=glibc
fi

if [ -z "${TEST_SET:-}" ]; then
  TEST_SET=default.tests
fi

# Note: Runtime-independent test sets like default.tests, sdk-does-not-exist.tests, and sdk-cannot-be-accessed.tests
# also use Node.js as the runtime for the container under test.
runtime="nodejs"
if [[ "$TEST_SET" = "dotnet.tests" ]]; then
  runtime="dotnet"
fi
if [[ "$TEST_SET" = "jvm.tests" ]]; then
  runtime="jvm"
fi

# We also use the Node.js test app for non-runtime specific tests (e.g. injector-integration-tests/tests/default.tests
# etc.), so this is the default Dockerfile.
dockerfile_name="injector-integration-tests/runtimes/nodejs/Dockerfile"
image_name=otel-injector-test-$ARCH-$LIBC-$runtime

base_image_run=unknown
base_image_build=unknown
case "$runtime" in
  "dotnet")
    dockerfile_name="injector-integration-tests/runtimes/dotnet/Dockerfile"
    base_image_build=mcr.microsoft.com/dotnet/sdk:9.0-bookworm-slim
    base_image_run=mcr.microsoft.com/dotnet/runtime:9.0-bookworm-slim
    if [[ "$LIBC" = "musl" ]]; then
      base_image_build=mcr.microsoft.com/dotnet/sdk:9.0-alpine
      base_image_run=mcr.microsoft.com/dotnet/runtime:9.0-alpine
    fi
    ;;
  "jvm")
    dockerfile_name="injector-integration-tests/runtimes/jvm/Dockerfile"
    base_image_run=eclipse-temurin:11
    if [[ "$LIBC" = "musl" ]]; then
      # Older images of eclipse-temurin:xx-alpine (before 21) are single platform and do not support arm64.
      base_image_run=eclipse-temurin:21-alpine
    fi
    ;;
  "nodejs")
    base_image_run=node:22.15.0-bookworm-slim
    if [[ "$LIBC" = "musl" ]]; then
      base_image_run=node:22.15.0-alpine3.21
    fi
    ;;
  *)
    echo "Unknown runtime: $runtime"
    exit 1
    ;;
esac

create_sdk_dummy_files_script="scripts/create-sdk-dummy-files.sh"
if [[ "$TEST_SET" = "sdk-does-not-exist.tests" ]]; then
  create_sdk_dummy_files_script="scripts/create-no-sdk-dummy-files.sh"
elif [[ "$TEST_SET" = "sdk-cannot-be-accessed.tests" ]]; then
  create_sdk_dummy_files_script="scripts/create-inaccessible-sdk-dummy-files.sh"
fi

docker rmi -f "$image_name" 2> /dev/null

set -x
docker build \
  --platform "$docker_platform" \
  --build-arg "base_image_build=${base_image_build}" \
  --build-arg "base_image_run=${base_image_run}" \
  --build-arg "injector_binary=${injector_binary}" \
  --build-arg "create_sdk_dummy_files_script=${create_sdk_dummy_files_script}" \
  . \
  -f "$dockerfile_name" \
  -t "$image_name"
{ set +x; } 2> /dev/null

docker_run_extra_options=""
docker_run_extra_arguments=""
if [ "${INTERACTIVE:-}" = "true" ]; then
  docker_run_extra_options="--interactive --tty"
  if [ "$LIBC" = glibc ]; then
    docker_run_extra_arguments=/bin/bash
  elif [ "$LIBC" = musl ]; then
    docker_run_extra_arguments=/bin/sh
  else
    echo "The libc flavor $LIBC is not supported."
    exit 1
  fi
fi

set -x
# shellcheck disable=SC2086
docker run $docker_run_extra_options \
  --rm \
  --platform "$docker_platform" \
  --env EXPECTED_CPU_ARCHITECTURE="$expected_cpu_architecture" \
  --env TEST_SET="$TEST_SET" \
  --env TEST_CASES="$TEST_CASES" \
  --env TEST_CASES_CONTAINING="$TEST_CASES_CONTAINING" \
  --env VERBOSE="${VERBOSE:-}" \
  "$image_name" \
  $docker_run_extra_arguments
{ set +x; } 2> /dev/null
