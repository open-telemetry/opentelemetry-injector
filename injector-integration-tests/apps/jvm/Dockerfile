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

# The *-binary-scan test sets take away what names the version of the Java home: its release file, and the version
# entry of a J9 class library's classlib.properties (the J9 VM needs the rest of that file to start). The injector
# then has to detect the Java version by scanning the VM binary, the way it does on runtimes that ship neither. This
# is declared after the layers above so that both variants of an image share them. Should an image move both, the
# build fails instead of the tests quietly passing through them again.
ARG remove_java_version=false
RUN if [ "$remove_java_version" = "true" ]; then \
      home="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"; \
      removed=; \
      if [ -f "$home/release" ]; then rm "$home/release" && removed=yes; fi; \
      if grep -q '^version=' "$home/lib/classlib.properties" 2>/dev/null; then \
        sed -i '/^version=/d' "$home/lib/classlib.properties" && removed=yes; \
      fi; \
      [ -n "$removed" ]; \
    fi

COPY dist/${injector_binary} /injector/libotelinject.so

CMD ["scripts/run-tests-within-container.sh"]
