FROM debian:trixie-20260406@sha256:3352c2e13876c8a5c5873ef20870e1939e73cb9a3c1aeba5e3e72172a85ce9ed

ARG ARCH=amd64
ARG tomcat_download_url

RUN apt-get update
RUN apt install -y default-jre

RUN apt-get install -y wget

ADD ${tomcat_download_url} apache-tomcat.tar.gz
RUN tar xzvf apache-tomcat.tar.gz && mv apache-tomcat-10.* apache-tomcat

# TODO The otel collector version needs to be kept up to date, potentially with renovate.
ADD https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.128.0/otelcol-contrib_0.128.0_linux_${ARCH}.deb otelcol-contrib_0.128.0_linux_${ARCH}.deb
RUN dpkg -i otelcol-contrib_0.128.0_linux_${ARCH}.deb

COPY instrumentation/dist/*${ARCH}.deb injector.deb

RUN dpkg -i injector.deb

RUN echo /usr/lib/opentelemetry/libotelinject.so >> /etc/ld.so.preload

COPY packaging/tests/shared/java/test.sh test.sh

CMD ["./test.sh"]
