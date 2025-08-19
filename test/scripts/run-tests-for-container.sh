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

runtime="node_js"
if [[ "$TEST_SET" = "jvm.tests" ]]; then
  runtime="jvm"
fi

dockerfile_name="test/docker/Dockerfile-node_js"
image_name=otel-injector-test-$ARCH-$LIBC-$runtime

base_image=unknown
case "$runtime" in
  "node_js")
    base_image=node:22.15.0-bookworm-slim
    if [[ "$LIBC" = "musl" ]]; then
      base_image=node:22.15.0-alpine3.21
    fi
    ;;
  "jvm")
    dockerfile_name="test/docker/Dockerfile-jvm"
    base_image=eclipse-temurin:11
    if [[ "$LIBC" = "musl" ]]; then
      # Older images of eclipse-temurin:xx-alpine (before 21) are single platform and do not support arm64.
      base_image=eclipse-temurin:21-alpine
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
  --build-arg "base_image=${base_image}" \
  --build-arg "injector_binary=${injector_binary}" \
  --build-arg "arch_under_test=${ARCH}" \
  --build-arg "libc_under_test=${LIBC}" \
  --build-arg "create_sdk_dummy_files_script=${create_sdk_dummy_files_script}" \
  . \
  -f "$dockerfile_name" \
  -t "$image_name"
{ set +x; } 2> /dev/null

docker_run_extra_arguments=""
if [ "${INTERACTIVE:-}" = "true" ]; then
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
docker run \
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
