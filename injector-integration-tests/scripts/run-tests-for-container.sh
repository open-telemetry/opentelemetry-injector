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
test_app="nodejs"
if [[ "$TEST_SET" = "dotnet.tests" ]]; then
  test_app="dotnet"
fi
if [[ "$TEST_SET" = "jvm.tests" ]]; then
  test_app="jvm"
fi
if [[ "$TEST_SET" = "no-getenv-symbol.tests" ]]; then
  test_app="no-getenv-symbol"
fi
if [[ "$TEST_SET" = "python.tests" ]]; then
  test_app="python"
fi
if [[ "$TEST_SET" = "no-libdl.tests" ]]; then
  test_app="no-libdl"
fi
if [[ "$TEST_SET" = "binary-validation.tests" ]]; then
  test_app="binary-validation"
fi
if [[ "$TEST_SET" = "copy-reloc.tests" ]]; then
  test_app="copy-reloc"
fi

# We also use the Node.js test app for non-runtime specific tests (e.g. injector-integration-tests/tests/default.tests
# etc.), so this is the default Dockerfile.
dockerfile_name="injector-integration-tests/apps/nodejs/Dockerfile"
image_name="otel-injector-test-$ARCH-$LIBC-$test_app"

base_image_run=unknown
base_image_build=unknown
case "$test_app" in
  "dotnet")
    dockerfile_name="injector-integration-tests/apps/dotnet/Dockerfile"
    base_image_build=mcr.microsoft.com/dotnet/sdk:9.0-bookworm-slim
    base_image_run=mcr.microsoft.com/dotnet/runtime:9.0-bookworm-slim
    if [[ "$LIBC" = "musl" ]]; then
      base_image_build=mcr.microsoft.com/dotnet/sdk:9.0-alpine
      base_image_run=mcr.microsoft.com/dotnet/runtime:9.0-alpine
    fi
    ;;
  "jvm")
    dockerfile_name="injector-integration-tests/apps/jvm/Dockerfile"
    base_image_build=maven:3.9-eclipse-temurin-21
    base_image_run=eclipse-temurin:21-jre
    if [[ "$LIBC" = "musl" ]]; then
      base_image_build=maven:3.9-eclipse-temurin-21-alpine
      base_image_run=eclipse-temurin:21-jre-alpine
    fi
    ;;
  "nodejs")
    base_image_run=node:22.15.0-bookworm-slim
    if [[ "$LIBC" = "musl" ]]; then
      base_image_run=node:22.15.0-alpine3.21
    fi
    ;;
  "python")
    dockerfile_name="injector-integration-tests/apps/python/Dockerfile"
    base_image_run=python:3.14-slim-bookworm
    if [[ "$LIBC" = "musl" ]]; then
      base_image_run=python:3.14-alpine3.23
    fi
    ;;
  "no-getenv-symbol")
    dockerfile_name="injector-integration-tests/apps/no-getenv-symbol/Dockerfile"
    base_image_run=golang:1.26.3-trixie
    # We do not provide a different base image depending on the libc flavor, the point of this test scenario is to test
    # an app that depends on no libc whatsoever, so the test is the same for LIBC=musl and LIBC=glibc.
    ;;
  "no-libdl")
    dockerfile_name="injector-integration-tests/apps/no-libdl/Dockerfile"
    base_image_run=debian:bullseye-slim
    # We do not provide a different base image depending on the libc flavor: the tests themselves skip for LIBC=musl
    # because musl uses a different libc-detection path that is not affected by this bug.
    ;;
  "binary-validation")
    dockerfile_name="injector-integration-tests/apps/binary-validation/Dockerfile"
    base_image_run=debian:bookworm-slim
    ;;
  "copy-reloc")
    dockerfile_name="injector-integration-tests/apps/copy-reloc/Dockerfile"
    # node:16-bullseye-slim provides Debian Bullseye (glibc 2.31, i.e. < 2.34) plus a node binary whose
    # /usr/local/bin/node carries an R_*_COPY relocation on __environ. We do not provide a musl variant
    # because the tests themselves skip for LIBC=musl: the bug is in the glibc-specific fallback path.
    base_image_run=node:16-bullseye-slim
    ;;
  *)
    echo "Unknown test app: $test_app"
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

if [ "$LIBC" = "musl" ]; then
  dotnet_arch="linux-musl-${ARCH/amd64/x64}"
else
  dotnet_arch="linux-${ARCH/amd64/x64}"
fi

set -x
# shellcheck disable=SC2086
docker run $docker_run_extra_options \
  --rm \
  --platform "$docker_platform" \
  --env EXPECTED_CPU_ARCHITECTURE="$expected_cpu_architecture" \
  --env LIBC_FLAVOR="$LIBC" \
  --env DOTNET_ARCH="$dotnet_arch" \
  --env TEST_SET="$TEST_SET" \
  --env TEST_CASES="${TEST_CASES:-}" \
  --env TEST_CASES_CONTAINING="${TEST_CASES_CONTAINING:-}" \
  --env VERBOSE="${VERBOSE:-}" \
  "$image_name" \
  $docker_run_extra_arguments
{ set +x; } 2> /dev/null
