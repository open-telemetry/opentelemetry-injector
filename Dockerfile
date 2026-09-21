ARG DOCKER_REPO=docker.io
FROM ${DOCKER_REPO}/alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6 AS build-injector

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
