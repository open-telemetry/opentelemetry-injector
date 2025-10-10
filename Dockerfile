ARG DOCKER_REPO=docker.io
FROM ${DOCKER_REPO}/alpine:3.22.2@sha256:4b7ce07002c69e8f3d704a9c5d6fd3053be500b7f1c69fc0d80990c2ad8dd412 AS build-injector

RUN apk add --no-cache make

COPY zig-version /otel-injector-test-build/zig-version
RUN source /otel-injector-test-build/zig-version && \
  apk add zig="$ZIG_VERSION" --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community

WORKDIR /libotelinject

COPY Makefile .
COPY build.zig .
COPY build.zig.zon .
COPY src src
