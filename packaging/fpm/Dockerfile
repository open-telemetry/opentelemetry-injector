FROM node:24-bookworm@sha256:032e78d7e54e352129831743737e3a83171d9cc5b5896f411649c597ce0b11ea

VOLUME /repo
WORKDIR /repo

ENV PACKAGE="deb"
ENV VERSION=""
ENV ARCH="amd64"
ENV OUTPUT_DIR="/repo/instrumentation/dist/"

COPY install-deps.sh Gemfile Gemfile.lock /

RUN /install-deps.sh

RUN git config --global --add safe.directory /repo

