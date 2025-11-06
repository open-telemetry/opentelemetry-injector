FROM fedora:41

ARG ARCH=amd64
ARG RPM_ARCH=x86_64
ARG tomcat_download_url

ENV LANG=C.UTF-8

RUN dnf -y update && \
    dnf -y install nodejs npm wget && \
    dnf clean all

RUN mkdir my_express_app && \
    cd my_express_app && \
    npm init -y && \
    npm install express --save

# TODO The otel collector version needs to be kept up to date, potentially with renovate.
RUN wget https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.128.0/otelcol-contrib_0.128.0_linux_${ARCH}.rpm
RUN rpm -i otelcol-contrib_0.128.0_linux_${ARCH}.rpm

COPY instrumentation/dist/*${RPM_ARCH}.rpm injector.rpm

RUN rpm -i injector.rpm

RUN echo /usr/lib/opentelemetry/libotelinject.so >> /etc/ld.so.preload

COPY packaging/tests/shared/nodejs/app.js my_express_app/app.js
COPY packaging/tests/shared/nodejs/test.sh test.sh

CMD ["./test.sh"]