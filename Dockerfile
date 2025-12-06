ARG DOCKER_REPO=docker.io
FROM ${DOCKER_REPO}/alpine:3.23.0@sha256:51183f2cfa6320055da30872f211093f9ff1d3cf06f39a0bdb212314c5dc7375 AS build-injector

RUN apk add --no-cache make

COPY zig-version /otel-injector-test-build/zig-version
RUN source /otel-injector-test-build/zig-version && \
  apk add zig="$ZIG_VERSION" --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community

WORKDIR /libotelinject

COPY Makefile .
COPY build.zig .
COPY build.zig.zon .
COPY src src
