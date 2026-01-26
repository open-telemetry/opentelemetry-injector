# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

ARG base_image_run="eclipse-temurin:25@sha256:42fc3fe6804ec612f5ef8a613f8c06d8dd578de6207336077387d4cb32edaa9b"
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

COPY injector-integration-tests/runtimes/jvm/no-op-agent no-op-agent
RUN cd no-op-agent/src/main/java && javac io/opentelemetry/javaagent/NoOpAgent.java && \
    jar -c -m manifest.mf -f no-op-agent.jar io/opentelemetry/javaagent/NoOpAgent.class && \
    cp no-op-agent.jar ../../../

COPY injector-integration-tests/runtimes/jvm app
RUN cd app && javac Main.java && \
    jar cfe Main.jar Main Main.class

COPY injector-integration-tests/scripts/run-tests-within-container.sh scripts/
COPY injector-integration-tests/scripts/create-*.sh scripts/
COPY injector-integration-tests/tests/*.tests tests/
COPY injector-integration-tests/common/otelinject.conf otelinject.conf
COPY injector-integration-tests/common/otelinject.custom-location.conf /custom/config/path/otelinject.conf
COPY injector-integration-tests/common/default_auto_instrumentation_env.conf default_auto_instrumentation_env.conf

RUN ${create_sdk_dummy_files_script}

COPY dist/${injector_binary} /injector/libotelinject.so

CMD ["scripts/run-tests-within-container.sh"]
