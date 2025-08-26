#!/bin/bash

set -e

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
cd $SCRIPT_DIR/../../..

set -x
docker build --platform "$docker_platform" --build-arg "ARCH=$ARCH" -t "instrumentation-java-$arch" -f packaging/tests/java/Dockerfile .
docker run --platform "$docker_platform" --rm -it "instrumentation-java-$arch"
