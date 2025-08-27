#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# See https://ziglang.org/download/ for the correct strings for zig_architecture. (Needs to match the architecture part
# of the download URL.)
ARCH="${ARCH:-amd64}"
if [[ "$ARCH" = arm64 ]]; then
  docker_platform=linux/arm64
  zig_architecture=aarch64
elif [[ "$ARCH" = amd64 ]]; then
  docker_platform=linux/amd64
  zig_architecture=x86_64
else
  echo "The architecture $ARCH is not supported."
  exit 1
fi

image_name="otel-injector-dev-$ARCH"
docker rmi -f "$image_name" 2> /dev/null || true
docker build \
  --platform "$docker_platform" \
  --build-arg "zig_architecture=${zig_architecture}" \
  -f devel.Dockerfile \
  -t "$image_name" \
  .

container_name="$image_name"
docker rm -f "$container_name" 2> /dev/null || true
docker run \
  --platform "$docker_platform" \
  --rm \
  -it \
  --name "$container_name" \
  --volume "$(pwd):/injector" \
  "$image_name" \
  /bin/bash
