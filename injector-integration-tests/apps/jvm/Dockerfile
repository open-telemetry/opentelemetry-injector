# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

ARG base_image_build="maven:3.9-eclipse-temurin-21"
ARG base_image_run="eclipse-temurin:21-jre"

FROM --platform=$BUILDPLATFORM ${base_image_build} AS build

WORKDIR /usr/src/otel/injector/

COPY injector-integration-tests/apps/jvm /usr/src/otel/injector/
RUN mvn package -B -q

# final stage/image
FROM ${base_image_run}

RUN mkdir -p /etc/opentelemetry/injector/conf.d && chmod -R 777 /etc/opentelemetry

WORKDIR /usr/src/otel/injector/
COPY --from=build /usr/src/otel/injector/no-op-agent/target/no-op-agent.jar no-op-agent/no-op-agent.jar
COPY --from=build /usr/src/otel/injector/app/target/Main.jar app/Main.jar

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

COPY injector-integration-tests/scripts/*.sh scripts/
COPY injector-integration-tests/tests/*.tests tests/
COPY injector-integration-tests/common/ common/
COPY injector-integration-tests/common/injector.custom-location.conf /custom/config/path/injector.conf

RUN scripts/create-config-file-directory.sh
RUN ${create_sdk_dummy_files_script}

COPY dist/${injector_binary} /injector/libotelinject.so

CMD ["scripts/run-tests-within-container.sh"]
