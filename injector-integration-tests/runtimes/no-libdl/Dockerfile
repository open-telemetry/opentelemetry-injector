# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# debian:bullseye-slim ships glibc 2.31. On glibc < 2.34, dlsym is exported by
# libdl.so, not by libc.so itself (the two were merged in glibc 2.34). The test
# app is a plain C binary compiled without -ldl, so libdl.so never appears in
# /proc/self/maps. This combination reproduces the libc-detection failure seen
# on RHEL 8 and similar pre-glibc-2.34 systems when a binary does not link libdl.
# TODO: pin to a specific digest once the test is green.
ARG base_image_run="debian:bullseye-slim"
FROM ${base_image_run}

ARG injector_binary
RUN if [ -z "$injector_binary" ]; then \
      echo "Error: build argument injector_binary is required but not set."; \
      exit 1; \
    fi

RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc libc6-dev \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/opentelemetry/injector/conf.d && chmod -R 777 /etc/opentelemetry

WORKDIR /usr/src/otel/injector

COPY injector-integration-tests/runtimes/no-libdl/app.c .
RUN mkdir -p app && gcc -o app/printenv app.c && rm app.c

COPY injector-integration-tests/scripts/run-tests-within-container.sh scripts/
COPY injector-integration-tests/scripts/create-*.sh scripts/
COPY injector-integration-tests/tests/*.tests tests/
COPY injector-integration-tests/common/injector.conf injector.conf
COPY injector-integration-tests/common/injector.custom-location.conf /custom/config/path/injector.conf
COPY injector-integration-tests/common/default_auto_instrumentation_env.conf default_auto_instrumentation_env.conf

COPY dist/${injector_binary} /injector/libotelinject.so

CMD ["scripts/run-tests-within-container.sh"]
