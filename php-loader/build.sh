#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# Builds the universal loader for one {libc, arch} pair into
#   dist/php/<libc>/<arch>/otel_loader.so
#
# Usage: build.sh [libc] [arch]
#   libc: glibc | musl | all   (default: all)
#   arch: amd64 | arm64 | all  (default: the host architecture)

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
repo_root="$(cd .. && pwd)"

# The PHP version whose headers we compile against. Deliberately the oldest
# supported one; see Dockerfile.build.
php_build_version="${PHP_BUILD_VERSION:-8.1}"

libc_arg="${1:-all}"
if [[ "${2:-}" != "" ]]; then
  arch_arg="$2"
elif [[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]]; then
  arch_arg="arm64"
else
  arch_arg="amd64"
fi

case "$libc_arg" in
  all) libcs=(glibc musl) ;;
  glibc | musl) libcs=("$libc_arg") ;;
  *)
    echo "unknown libc flavor: $libc_arg (expected glibc, musl or all)" >&2
    exit 1
    ;;
esac

case "$arch_arg" in
  all) arches=(amd64 arm64) ;;
  amd64 | arm64) arches=("$arch_arg") ;;
  *)
    echo "unknown architecture: $arch_arg (expected amd64, arm64 or all)" >&2
    exit 1
    ;;
esac

for libc in "${libcs[@]}"; do
  if [[ "$libc" == "musl" ]]; then
    build_image="php:${php_build_version}-cli-alpine"
  else
    build_image="php:${php_build_version}-cli"
  fi

  for arch in "${arches[@]}"; do
    out_dir="${repo_root}/dist/php/${libc}/${arch}"
    echo "==> building the loader for ${libc}/${arch} against ${build_image}"
    mkdir -p "$out_dir"
    docker buildx build \
      --platform "linux/${arch}" \
      --build-arg "PHP_BUILD_IMAGE=${build_image}" \
      --target export \
      --output "type=local,dest=${out_dir}" \
      -f Dockerfile.build \
      .
    echo "    -> ${out_dir}/otel_loader.so"
  done
done
