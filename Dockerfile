ARG DOCKER_REPO=docker.io
FROM ${DOCKER_REPO}/alpine:3.23.2@sha256:865b95f46d98cf867a156fe4a135ad3fe50d2056aa3f25ed31662dff6da4eb62 AS build-injector

RUN apk add --no-cache make

ARG ZIG_ARCHITECTURE

RUN mkdir -p /opt/zig
WORKDIR /opt/zig
COPY zig-version .
RUN . /opt/zig/zig-version && \
  wget -q -O /tmp/zig.tar.gz https://ziglang.org/download/${ZIG_VERSION%-*}/zig-${ZIG_ARCHITECTURE}-linux-${ZIG_VERSION}.tar.xz && \
  tar --strip-components=1 -xf /tmp/zig.tar.gz
ENV PATH="$PATH:/opt/zig"

WORKDIR /libotelinject

COPY Makefile .
COPY build.zig .
COPY build.zig.zon .
COPY src src
