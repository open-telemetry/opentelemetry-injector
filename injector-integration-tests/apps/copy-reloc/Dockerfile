# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# node:16-bullseye-slim ships glibc 2.31 and a node binary that contains a COPY
# relocation on environ (verified via `readelf -r /usr/local/bin/node`). This
# exercises the glibc < 2.34 fallback path where the injector resolves getenv
# directly from the ELF symbol table rather than via dlsym.
ARG base_image_run="node:16-bullseye-slim@sha256:503446c15c6236291222f8192513c2eb56a02a8949cbadf4fe78cce19815c734"
FROM ${base_image_run}

ARG injector_binary
RUN if [ -z "$injector_binary" ]; then \
      echo "Error: build argument injector_binary is required but not set."; \
      exit 1; \
    fi

ARG create_sdk_dummy_files_script
RUN if [ -z "$create_sdk_dummy_files_script" ]; then \
      echo "Error: build argument create_sdk_dummy_files_script is required but not set."; \
      exit 1; \
    fi

RUN mkdir -p /etc/opentelemetry/injector/conf.d && chmod -R 777 /etc/opentelemetry

WORKDIR /usr/src/otel/injector/

COPY injector-integration-tests/apps/copy-reloc/no-op-agent no-op-agent

COPY injector-integration-tests/apps/copy-reloc app

COPY injector-integration-tests/scripts/*.sh scripts/
COPY injector-integration-tests/tests/*.tests tests/
COPY injector-integration-tests/common/conf.d/ /etc/opentelemetry/injector/conf.d/
COPY injector-integration-tests/common/injector.conf injector.conf
COPY injector-integration-tests/common/injector.custom-location.conf /custom/config/path/injector.conf
COPY injector-integration-tests/common/default_env.conf common/default_env.conf

RUN ${create_sdk_dummy_files_script}

COPY dist/${injector_binary} /injector/libotelinject.so

USER node
CMD ["scripts/run-tests-within-container.sh"]
