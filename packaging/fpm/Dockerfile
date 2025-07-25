FROM node:24-bookworm@sha256:c7a63f857d6dc9b3780ceb1874544cc22f3e399333c82de2a46de0049e841729

VOLUME /repo
WORKDIR /repo

ENV PACKAGE="deb"
ENV VERSION=""
ENV ARCH="amd64"
ENV OUTPUT_DIR="/repo/instrumentation/dist/"

COPY install-deps.sh Gemfile Gemfile.lock /

RUN /install-deps.sh

RUN git config --global --add safe.directory /repo

CMD ./packaging/fpm/$PACKAGE/build.sh "$VERSION" "$ARCH" "$OUTPUT_DIR"
