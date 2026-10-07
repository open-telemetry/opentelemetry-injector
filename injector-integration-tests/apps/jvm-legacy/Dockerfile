# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# Build the NoOp agent using JDK 8 like the OTel Java agent. If this is injected by the injector in the 
# Java 1.6 app below it will fail with incompatible class version error.
ARG base_image_build="eclipse-temurin:8-jdk"
ARG base_image_run="vulhub/openjdk:oracle-jdk-6@sha256:35e7972fd3bec182151ec5b61832197e1655609b6a7bf7babebda33318ef5eb1"

FROM --platform=$BUILDPLATFORM ${base_image_build} AS agent-build

WORKDIR /usr/src/otel/agent
COPY injector-integration-tests/apps/jvm/no-op-agent/src/main/java/io/opentelemetry/javaagent/NoOpAgent.java NoOpAgent.java
RUN mkdir -p classes \
    && javac -source 8 -target 8 -d classes NoOpAgent.java \
    && printf 'Manifest-Version: 1.0\nPremain-Class: io.opentelemetry.javaagent.NoOpAgent\n\n' > agent-manifest \
    && jar cfm no-op-agent.jar agent-manifest -C classes io

FROM ${base_image_run}

WORKDIR /usr/src/otel/injector

COPY injector-integration-tests/apps/jvm-legacy/app/ app/
COPY --from=agent-build /usr/src/otel/agent/no-op-agent.jar no-op-agent/no-op-agent.jar
COPY injector-integration-tests/apps/jvm/no-op-agent/src/main/java/io/opentelemetry/javaagent/NoOpAgent.java /tmp/NoOpAgent.java

# Compile the app with Java 6, plus a separate compatible agent used only for
# user-supplied-agent and lowered-minimum-version tests. The default injected agent is Java 8.
RUN mkdir -p java6-agent \
    && javac -d app app/Main.java \
    && javac -d java6-agent /tmp/NoOpAgent.java \
    && printf 'Manifest-Version: 1.0\nPremain-Class: io.opentelemetry.javaagent.NoOpAgent\n\n' > /tmp/agent-manifest \
    && jar cfm java6-agent/java6-agent.jar /tmp/agent-manifest -C java6-agent io \
    && ln -s "$JAVA_HOME/bin/java" app/java-symlink \
    && rm /tmp/NoOpAgent.java /tmp/agent-manifest

ARG injector_binary
ARG create_sdk_dummy_files_script

COPY injector-integration-tests/scripts/*.sh scripts/
COPY injector-integration-tests/tests/*.tests tests/
COPY injector-integration-tests/common/ common/
COPY injector-integration-tests/common/injector.custom-location.conf /custom/config/path/injector.conf
COPY injector-integration-tests/common/injector.jvm-minimum-java-version.conf /custom/config/path/jvm-minimum.conf

RUN scripts/create-config-file-directory.sh \
    && ${create_sdk_dummy_files_script} \
    && cp java6-agent/java6-agent.jar /usr/lib/opentelemetry/jvm/java6-agent.jar

COPY dist/${injector_binary} /injector/libotelinject.so

CMD ["scripts/run-tests-within-container.sh"]
