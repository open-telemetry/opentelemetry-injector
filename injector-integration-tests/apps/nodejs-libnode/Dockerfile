# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# Debian (like Ubuntu and Fedora) builds Node.js as a shared library: /usr/bin/node is a small executable that exports
# nothing itself and depends on libnode.so.<ABI version>, which exports the Node.js API. The official Node.js images
# used by the other Node.js test sets ship a single node executable that exports the API itself.
ARG base_image_run="debian:bookworm-slim"
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

RUN apt-get update \
  && apt-get install --yes --no-install-recommends nodejs \
  && rm -rf /var/lib/apt/lists/*

# Fail the build if the distribution ever stops linking node against libnode.so, since this test set would then no
# longer test what it is meant to test.
RUN if ! ldd /usr/bin/node | grep -q 'libnode\.so'; then \
      echo "Error: /usr/bin/node does not depend on libnode.so."; \
      ldd /usr/bin/node; \
      exit 1; \
    fi

RUN useradd --create-home node

RUN mkdir -p /etc/opentelemetry/injector/conf.d && chmod -R 777 /etc/opentelemetry

WORKDIR /usr/src/otel/injector/

COPY injector-integration-tests/apps/nodejs/no-op-agent no-op-agent

COPY injector-integration-tests/apps/nodejs app

COPY injector-integration-tests/scripts/*.sh scripts/
COPY injector-integration-tests/tests/*.tests tests/
COPY injector-integration-tests/common/ common/
COPY injector-integration-tests/common/injector.custom-location.conf /custom/config/path/injector.conf

RUN scripts/create-config-file-directory.sh
RUN ${create_sdk_dummy_files_script}

COPY dist/${injector_binary} /injector/libotelinject.so

USER node
CMD ["scripts/run-tests-within-container.sh"]
