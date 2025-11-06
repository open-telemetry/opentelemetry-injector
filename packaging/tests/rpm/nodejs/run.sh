#!/bin/bash

set -euo pipefail

arch="${ARCH:-amd64}"
if [ "$arch" = arm64 ]; then
  docker_platform=linux/arm64
elif [ "$arch" = amd64 ]; then
  docker_platform=linux/amd64
else
  echo "The architecture $arch is not supported."
  exit 1
fi

SCRIPT_DIR="$( cd "$( dirname ${BASH_SOURCE[0]} )" && pwd )"
cd $SCRIPT_DIR/../../../..

docker build \
  --platform "$docker_platform" \
  --build-arg "ARCH=$arch" \
  -t "instrumentation-nodejs-$arch" \
  -f packaging/tests/rpm/nodejs/Dockerfile \
  .
docker run \
  --platform "$docker_platform" \
  --rm \
  "instrumentation-nodejs-$arch"
