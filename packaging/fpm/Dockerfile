FROM node:24-bookworm@sha256:00e9195ebd49985a6da8921f419978d85dfe354589755192dc090425ce4da2f7

VOLUME /repo
WORKDIR /repo

ENV PACKAGE="deb"
ENV VERSION=""
ENV ARCH="amd64"
ENV OUTPUT_DIR="/repo/instrumentation/dist/"

COPY install-deps.sh Gemfile Gemfile.lock /

RUN /install-deps.sh

RUN git config --global --add safe.directory /repo

