# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

ARG base_image_run="python:3.14-slim-bookworm"
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

COPY injector-integration-tests/runtimes/python/no-op-agent no-op-agent

COPY injector-integration-tests/runtimes/python app

COPY injector-integration-tests/scripts/run-tests-within-container.sh scripts/
COPY injector-integration-tests/scripts/create-*.sh scripts/
COPY injector-integration-tests/tests/*.tests tests/
ADD injector-integration-tests/runtimes/python/otelinject-enable-python.conf /etc/opentelemetry/otelinject.conf
RUN chmod 777 /etc/opentelemetry/otelinject.conf
COPY injector-integration-tests/common/otelinject.conf otelinject.conf
COPY injector-integration-tests/common/otelinject.custom-location.conf /custom/config/path/otelinject.conf
COPY injector-integration-tests/common/default_auto_instrumentation_env.conf default_auto_instrumentation_env.conf

RUN ${create_sdk_dummy_files_script}

COPY dist/${injector_binary} /injector/libotelinject.so

CMD ["scripts/run-tests-within-container.sh"]