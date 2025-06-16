FROM debian:12

RUN apt-get update
RUN apt install -y default-jre

RUN apt-get install -y wget

RUN wget https://dlcdn.apache.org/tomcat/tomcat-10/v10.1.42/bin/apache-tomcat-10.1.42.tar.gz
RUN tar xzvf apache-tomcat-10.1.42.tar.gz

RUN wget https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.128.0/otelcol-contrib_0.128.0_linux_amd64.deb
RUN dpkg -i otelcol-contrib_0.128.0_linux_amd64.deb

COPY instrumentation/dist/*.deb injector.deb

RUN dpkg -i injector.deb

RUN echo /usr/lib/opentelemetry/libotelinject.so >> /etc/ld.so.preload

COPY packaging/tests/java/test.sh test.sh

CMD ["./test.sh"]