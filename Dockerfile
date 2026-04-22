ARG DOCKER_REPO=docker.io
FROM ${DOCKER_REPO}/alpine:3.23.4@sha256:5b10f432ef3da1b8d4c7eb6c487f2f5a8f096bc91145e68878dd4a5019afde11 AS build-injector

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
