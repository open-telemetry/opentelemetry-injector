ARG DOCKER_REPO=docker.io
FROM ${DOCKER_REPO}/alpine:3.21.3 AS build-injector

RUN apk add --no-cache make

COPY zig-version /otel-injector-test-build/zig-version
RUN source /otel-injector-test-build/zig-version && \
  apk add zig="$ZIG_VERSION" --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community

WORKDIR /libotelinject

COPY Makefile .
COPY build.zig .
COPY build.zig.zon .
COPY src src
