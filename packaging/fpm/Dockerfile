FROM node:24-bookworm@sha256:e9891237dfbb1de60ce19e9ff9fac5d73ad9c37da303ad72ff2a425ad1057e71

VOLUME /repo
WORKDIR /repo

ENV PACKAGE="deb"
ENV VERSION=""
ENV ARCH="amd64"
ENV OUTPUT_DIR="/repo/instrumentation/dist/"

COPY install-deps.sh Gemfile Gemfile.lock /

RUN /install-deps.sh

RUN git config --global --add safe.directory /repo

