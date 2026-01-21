# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# Dockerfile for binary validation tests.
# Uses a minimal Debian image with binutils installed for readelf.

ARG base_image_run="debian:bookworm-slim"
FROM ${base_image_run}

ARG injector_binary
RUN if [ -z "$injector_binary" ]; then \
      echo "Error: build argument injector_binary is required but not set."; \
      exit 1; \
    fi

# Install binutils (provides readelf) for binary validation tests.
# Detect package manager and install accordingly (apt for Debian, apk for Alpine).
RUN apt-get update && apt-get install -y --no-install-recommends binutils

RUN mkdir -p /etc/opentelemetry && chmod 777 /etc/opentelemetry

WORKDIR /usr/src/otel/injector/

COPY injector-integration-tests/binary/run-tests.sh scripts/
COPY injector-integration-tests/tests/binary-validation.tests tests/

COPY dist/${injector_binary} /injector/libotelinject.so

CMD ["scripts/run-tests.sh"]