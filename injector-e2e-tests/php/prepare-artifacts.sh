#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# Puts an OpenTelemetry PHP artifact tree in dist/artifacts, in the layout
# ghcr.io/opentelemetry-php/autoinstrumentation-php publishes and the loader expects:
#
#   dist/artifacts/<module_api>/<libc>/<zts|non-zts>/{opentelemetry.so,autoload.php,...}
#
# Prefers the published upstream image, because testing against the real artifacts is the point.
# Upstream's manifest advertises four architectures but its non-amd64 images currently contain
# x86-64 binaries, so the extension's ELF machine is checked against the host and a local build
# is used instead when they disagree. That check is deliberately not a hard-coded "arm64 is
# broken": it starts using upstream automatically once the image is fixed.
#
# Usage: prepare-artifacts.sh [php-minor] [module-api]     (default: 8.3 20230831)

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
repo_root="$(cd ../.. && pwd)"

php_minor="${1:-8.3}"
module_api="${2:-20230831}"
libc=glibc
upstream_image="${UPSTREAM_ARTIFACT_IMAGE:-ghcr.io/opentelemetry-php/autoinstrumentation-php:latest}"

case "$(uname -m)" in
  arm64 | aarch64)
    arch=arm64
    expected_machine="b7 00"
    ;;
  *)
    arch=amd64
    expected_machine="3e 00"
    ;;
esac

out_root="${repo_root}/dist/artifacts"
variant_dir="${out_root}/${module_api}/${libc}/non-zts"

build_locally() {
  echo "==> building artifacts locally for ${libc}/${arch} (PHP ${php_minor}, module API ${module_api})"
  rm -rf "$variant_dir"
  mkdir -p "$variant_dir"
  docker buildx build \
    --platform "linux/${arch}" \
    --build-arg "PHP_IMAGE=php:${php_minor}-cli" \
    --target export \
    --output "type=local,dest=${variant_dir}" \
    -f Dockerfile.artifacts \
    "$repo_root"
}

if [[ "${OTEL_PHP_ARTIFACTS_SOURCE:-auto}" == "local" ]]; then
  build_locally
else
  echo "==> extracting artifacts from ${upstream_image} (${arch})"
  rm -rf "$out_root"
  mkdir -p "$out_root"
  container="otel-php-artifacts-$$"
  docker rm -f "$container" > /dev/null 2>&1 || true
  docker create --platform "linux/${arch}" --name "$container" "$upstream_image" > /dev/null
  docker cp "${container}:/autoinstrumentation/." "$out_root/"
  docker rm -f "$container" > /dev/null

  extension="${variant_dir}/opentelemetry.so"
  machine=""
  [[ -f "$extension" ]] && machine="$(od -An -tx1 -j18 -N2 "$extension" | tr -s ' ' | sed 's/^ //;s/ $//')"

  if [[ "$machine" != "$expected_machine" ]]; then
    echo "    upstream image is unusable on this host: ${extension} has ELF machine '${machine}'," >&2
    echo "    expected '${expected_machine}' for ${arch}. Falling back to a local build." >&2
    echo "    (upstream bug: the image's multi-architecture manifest does not match its payload)" >&2
    build_locally
  fi
fi

test -f "${variant_dir}/opentelemetry.so"
test -f "${variant_dir}/autoload.php"
echo "    -> ${variant_dir}"
