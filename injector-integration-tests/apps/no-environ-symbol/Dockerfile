# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

ARG base_image_run="golang:1.26.3-trixie@sha256:fb4b74a39c7318d53539ebda43ccd3ecba6e447a78591889c0efc0a7235ea8b3"
FROM ${base_image_run}

ARG injector_binary
RUN if [ -z "$injector_binary" ]; then \
      echo "Error: build argument injector_binary is required but not set."; \
      exit 1; \
    fi

RUN mkdir -p /etc/opentelemetry/injector/conf.d && chmod -R 777 /etc/opentelemetry

WORKDIR /usr/src/otel/injector

COPY injector-integration-tests/apps/no-environ-symbol/go.mod .
COPY injector-integration-tests/apps/no-environ-symbol/go.sum .
RUN go mod download
COPY injector-integration-tests/apps/no-environ-symbol/main.go .

ARG TARGETOS
ARG TARGETARCH

RUN GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} go build -v -buildmode=pie -ldflags '-s -w' -o app/noenviron .

COPY injector-integration-tests/scripts/*.sh scripts/
COPY injector-integration-tests/tests/*.tests tests/
COPY injector-integration-tests/common/ common/
COPY injector-integration-tests/common/injector.exclude-noenviron.conf injector.exclude-noenviron.conf

COPY dist/${injector_binary} /injector/libotelinject.so

CMD ["scripts/run-tests-within-container.sh"]
