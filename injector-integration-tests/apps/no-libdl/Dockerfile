# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# The Red Hat UBI 8 base image ships glibc 2.28. On glibc < 2.34, dlsym is
# exported by libdl.so, not by libc.so itself (the two were merged in glibc
# 2.34). The test app is a plain C binary compiled without -ldl, so libdl.so
# never appears in /proc/self/maps. This combination reproduces the
# libc-detection failure seen on RHEL 8 and similar pre-glibc-2.34 systems when
# a binary does not link libdl.
#
# Note: this used to be debian:bullseye-slim (glibc 2.31), but Debian 11 has
# reached its end of life, so its apt repositories no longer work (expired
# Release files, packages removed from the security pool). UBI 8 is supported
# until 2029 and is a closer match for the RHEL 8 systems the bug was reported
# on anyway.
ARG base_image_run="registry.access.redhat.com/ubi8/ubi:8.10@sha256:2dcfc23b79d88fdaeefc6ed0cfb144e41dca600bfa73c38ab5d8dca5b05d1b7f"
FROM ${base_image_run}

ARG injector_binary
RUN if [ -z "$injector_binary" ]; then \
      echo "Error: build argument injector_binary is required but not set."; \
      exit 1; \
    fi

RUN dnf install -y gcc glibc-devel \
    && dnf clean all

RUN mkdir -p /etc/opentelemetry/injector/conf.d && chmod -R 777 /etc/opentelemetry

WORKDIR /usr/src/otel/injector

COPY injector-integration-tests/apps/no-libdl/app.c .
RUN mkdir -p app && gcc -o app/printenv app.c && rm app.c

COPY injector-integration-tests/scripts/*.sh scripts/
COPY injector-integration-tests/tests/*.tests tests/
COPY injector-integration-tests/common/ common/

COPY dist/${injector_binary} /injector/libotelinject.so

CMD ["scripts/run-tests-within-container.sh"]
