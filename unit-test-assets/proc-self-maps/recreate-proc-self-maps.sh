#!/usr/bin/env bash

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

create_proc_maps() {
  local image="$1"
  local platform="$2"
  local output_file="$3"

  rm -f proc-self-maps
  docker run \
    --rm \
    --platform "$platform" \
    -v "$(pwd):/workspace" \
    "$image" \
    node /workspace/copy-proc-self-maps.js
  mv -f proc-self-maps "$output_file"
}

# musl/x86_64
create_proc_maps \
  node:24-alpine3.22 \
  linux/x86_64 \
  maps-musl-x86_64

# musl/arm64
create_proc_maps \
  node:24-alpine3.22 \
  linux/arm64 \
  maps-musl-arm64

# glibc/x86_64
create_proc_maps \
  node:24-bookworm-slim \
  linux/x86_64 \
  maps-glibc-x86_64

# glibc/arm64
create_proc_maps \
  node:24-bookworm-slim \
  linux/arm64 \
  maps-glibc-arm64

# glibc/x86_64 (bullseye, maps file does not mention libc.so.6)
create_proc_maps \
  node:24-bullseye-slim \
  linux/x86_64 \
  maps-glibc-x86_64-bullseye

# glibc/arm64 (bullseye, maps file does not mention libc.so.6)
create_proc_maps \
  node:24-bullseye-slim \
  linux/arm64 \
  maps-glibc-arm64-bullseye
