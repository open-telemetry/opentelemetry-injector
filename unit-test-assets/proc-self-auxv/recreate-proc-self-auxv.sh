#!/usr/bin/env bash

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

create_proc_auxv() {
  local image="$1"
  local platform="$2"
  local output_file="$3"

  rm -f proc-self-auxv
  docker run \
    --rm \
    --platform "$platform" \
    -v "$(pwd):/workspace" \
    "$image" \
    node /workspace/copy-proc-self-auxv.js
  mv -f proc-self-auxv "$output_file"
}

# musl/x86_64
create_proc_auxv \
  node:24-alpine3.23 \
  linux/x86_64 \
  auxv-musl-x86_64

# musl/arm64
create_proc_auxv \
  node:24-alpine3.23 \
  linux/arm64 \
  auxv-musl-arm64

# glibc/x86_64
create_proc_auxv \
  node:24-bookworm-slim \
  linux/x86_64 \
  auxv-glibc-x86_64

# glibc/arm64
create_proc_auxv \
  node:24-bookworm-slim \
  linux/arm64 \
  auxv-glibc-arm64
