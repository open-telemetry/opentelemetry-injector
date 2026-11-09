ARG DOCKER_REPO=docker.io
FROM ${DOCKER_REPO}/alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf AS build-injector

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
