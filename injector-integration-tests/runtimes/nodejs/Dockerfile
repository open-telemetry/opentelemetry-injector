# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

ARG base_image_run="node:24.13.0-bookworm-slim@sha256:bf22df20270b654c4e9da59d8d4a3516cce6ba2852e159b27288d645b7a7eedc"
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

RUN mkdir -p /etc/opentelemetry && chmod 777 /etc/opentelemetry

WORKDIR /usr/src/otel/injector/

COPY injector-integration-tests/runtimes/nodejs app

COPY injector-integration-tests/scripts/run-tests-within-container.sh scripts/
COPY injector-integration-tests/scripts/create-*.sh scripts/
COPY injector-integration-tests/tests/*.tests tests/
COPY injector-integration-tests/common/otelinject.conf otelinject.conf
COPY injector-integration-tests/common/otelinject.custom-location.conf /custom/config/path/otelinject.conf
COPY injector-integration-tests/common/default_auto_instrumentation_env.conf default_auto_instrumentation_env.conf

RUN ${create_sdk_dummy_files_script}

COPY dist/${injector_binary} /injector/libotelinject.so

USER node
CMD ["scripts/run-tests-within-container.sh"]
