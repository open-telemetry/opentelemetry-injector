# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

ARG base_image_run="golang:1.25.5-trixie"
FROM ${base_image_run}

ARG injector_binary
RUN if [ -z "$injector_binary" ]; then \
      echo "Error: build argument injector_binary is required but not set."; \
      exit 1; \
    fi

RUN mkdir -p /etc/opentelemetry && chmod 777 /etc/opentelemetry

WORKDIR /usr/src/otel/injector

COPY injector-integration-tests/runtimes/no-environ-symbol/go.mod .
COPY injector-integration-tests/runtimes/no-environ-symbol/go.sum .
RUN go mod download
COPY injector-integration-tests/runtimes/no-environ-symbol/main.go .

ARG TARGETOS
ARG TARGETARCH

RUN GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} go build -v -buildmode=pie -ldflags '-s -w' -o app/noenviron .

COPY injector-integration-tests/scripts/run-tests-within-container.sh scripts/
COPY injector-integration-tests/scripts/create-*.sh scripts/
COPY injector-integration-tests/tests/*.tests tests/
COPY injector-integration-tests/common/otelinject.conf otelinject.conf
COPY injector-integration-tests/common/otelinject.custom-location.conf /custom/config/path/otelinject.conf
COPY injector-integration-tests/common/default_auto_instrumentation_env.conf default_auto_instrumentation_env.conf

COPY dist/${injector_binary} /injector/libotelinject.so

CMD ["scripts/run-tests-within-container.sh"]
