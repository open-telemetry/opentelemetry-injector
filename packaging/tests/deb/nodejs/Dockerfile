FROM debian:12

ARG ARCH=amd64

RUN apt-get update
RUN apt install -y nodejs npm wget

RUN mkdir my_express_app && \
    cd my_express_app && \
    npm init -y && \
    npm install express --save


# TODO The otel collector version needs to be kept up to date, potentially with renovate.
RUN wget https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.128.0/otelcol-contrib_0.128.0_linux_${ARCH}.deb
RUN dpkg -i otelcol-contrib_0.128.0_linux_${ARCH}.deb

COPY instrumentation/dist/*${ARCH}.deb injector.deb

RUN dpkg -i injector.deb

RUN echo /usr/lib/opentelemetry/libotelinject.so >> /etc/ld.so.preload

COPY packaging/tests/shared/nodejs/app.js my_express_app/app.js
COPY packaging/tests/shared/nodejs/test.sh test.sh

CMD ["./test.sh"]