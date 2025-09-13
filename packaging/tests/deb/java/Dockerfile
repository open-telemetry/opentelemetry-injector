FROM debian:12

# TODO: Get arch target
ARG ARCH=amd64

COPY instrumentation/dist/*${ARCH}.deb injector.deb

RUN apt-get update
RUN apt install -y default-jre

RUN apt-get install -y wget

# TODO https://dlcdn.apache.org/tomcat/tomcat-10/ only always contains the latest 10.x release, so a path like
# tomcat/tomcat-10/v10.1.44 disappears somewhat frequently, making this test fragile. We should find a more stable way
# to install Tomcat at some point.
ADD https://dlcdn.apache.org/tomcat/tomcat-10/v10.1.45/bin/apache-tomcat-10.1.45.tar.gz apache-tomcat-10.1.45.tar.gz
RUN tar xzvf apache-tomcat-10.1.45.tar.gz && mv apache-tomcat-10.1.45 apache-tomcat

# TODO The otel collector version needs to be kept up to date, potentially with renovate.
ADD https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.128.0/otelcol-contrib_0.128.0_linux_${ARCH}.deb otelcol-contrib_0.128.0_linux_${ARCH}.deb
RUN dpkg -i otelcol-contrib_0.128.0_linux_${ARCH}.deb

RUN dpkg -i injector.deb

RUN echo /usr/lib/opentelemetry/libotelinject.so >> /etc/ld.so.preload

COPY packaging/tests/deb/java/test.sh test.sh

CMD ["./test.sh"]
