# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# node:16-bullseye-slim ships glibc 2.31 and a node binary that contains a COPY
# relocation on __environ (verified via `readelf -r /usr/local/bin/node`). On
# glibc < 2.34 the injector falls back to its own ELF symbol resolution rather
# than the dynamic linker, which means the libc.so __environ slot it looks up
# is *not* the BSS copy that ld.so redirects the process to. As a result, the
# injector reads an empty environment in this process and any pre-existing
# value of NODE_OPTIONS, OTEL_RESOURCE_ATTRIBUTES, etc. is invisible to it.
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

COPY injector-integration-tests/runtimes/copy-reloc-environ/no-op-agent no-op-agent

COPY injector-integration-tests/runtimes/copy-reloc-environ app

COPY injector-integration-tests/scripts/run-tests-within-container.sh scripts/
COPY injector-integration-tests/scripts/create-*.sh scripts/
COPY injector-integration-tests/tests/*.tests tests/
COPY injector-integration-tests/common/conf.d/ /etc/opentelemetry/injector/conf.d/
COPY injector-integration-tests/common/injector.conf injector.conf
COPY injector-integration-tests/common/injector.custom-location.conf /custom/config/path/injector.conf
COPY injector-integration-tests/common/default_auto_instrumentation_env.conf default_auto_instrumentation_env.conf

RUN ${create_sdk_dummy_files_script}

COPY dist/${injector_binary} /injector/libotelinject.so

USER node
CMD ["scripts/run-tests-within-container.sh"]
