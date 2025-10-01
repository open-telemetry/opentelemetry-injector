# This Dockerfile is intended to serve as a development environment for the injector, i.e. mounting the injector
# directory as a volume to the container and then running the image with `-it` to have a fast feeback cycle when working
# on injector changes.
# It also enables running unit tests on different architectures (x86_64 vs aarm64).
# Use `make docker-run` build and run the container.

ARG base_image=debian:13@sha256:fd8f5a1df07b5195613e4b9a0b6a947d3772a151b81975db27d47f093f60c6e6
FROM ${base_image}

ARG zig_architecture

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      autoconf \
      binutils \
      build-essential \
      ca-certificates \
      default-jre \
      entr \
      fd-find \
      gdb \
      less \
      locales \
      nodejs \
      tmux \
      rsyslog \
      vim \
      wget \
      && \
    apt-get clean && \
    localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8
ENV LANG=en_US.utf8
RUN ln -s $(which fdfind) /usr/local/bin/fd
RUN echo 'alias ll="ls -lah"' >> ~/.bashrc

# install Zig tooling.
RUN mkdir -p /opt/zig
WORKDIR /opt/zig
COPY zig-version .
RUN . /opt/zig/zig-version && \
  wget -q -O /tmp/zig.tar.gz https://ziglang.org/download/${ZIG_VERSION%-*}/zig-${zig_architecture}-linux-${ZIG_VERSION%-*}.tar.xz && \
  tar --strip-components=1 -xf /tmp/zig.tar.gz
ENV PATH="$PATH:/opt/zig"

# to see syslogs, run the following in the container
# apt install rsyslog
# service rsyslog start

WORKDIR /injector
