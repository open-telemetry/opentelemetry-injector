FROM node:24-bookworm@sha256:fdddfb3e688158251943d52eba361de991548f6814007acba4917ae6b512d6be

VOLUME /repo
WORKDIR /repo

ENV PACKAGE="deb"
ENV VERSION=""
ENV ARCH="amd64"
ENV OUTPUT_DIR="/repo/instrumentation/dist/"

COPY install-deps.sh Gemfile Gemfile.lock /

RUN /install-deps.sh

RUN git config --global --add safe.directory /repo

