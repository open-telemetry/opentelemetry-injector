ARG DOCKER_REPO=docker.io
FROM ${DOCKER_REPO}/alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 AS build-injector

RUN apk add --no-cache make

COPY zig-version /otel-injector-test-build/zig-version
RUN source /otel-injector-test-build/zig-version && \
  apk add zig="$ZIG_VERSION" --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community

WORKDIR /libotelinject

COPY Makefile .
COPY build.zig .
COPY build.zig.zon .
COPY src src
