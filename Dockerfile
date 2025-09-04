ARG DOCKER_REPO=docker.io
FROM ${DOCKER_REPO}/alpine:3.21.3@sha256:a8560b36e8b8210634f77d9f7f9efd7ffa463e380b75e2e74aff4511df3ef88c AS build-injector

RUN apk add --no-cache make

COPY zig-version /otel-injector-test-build/zig-version
RUN source /otel-injector-test-build/zig-version && \
  apk add zig="$ZIG_VERSION" --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community

WORKDIR /libotelinject

COPY Makefile .
COPY build.zig .
COPY build.zig.zon .
COPY src src
