# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# Builds the Node.js test app as a single executable application (SEA): a copy of the node executable with the app
# injected into it by postject (https://nodejs.org/api/single-executable-applications.html).
ARG base_image_run="node:22.15.0-bookworm-slim"
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

COPY injector-integration-tests/apps/nodejs/no-op-agent no-op-agent

COPY injector-integration-tests/apps/nodejs/index.js app/index.js
RUN cd app \
  && echo '{ "main": "index.js", "output": "sea-prep.blob", "disableExperimentalSEAWarning": true }' > sea-config.json \
  && node --experimental-sea-config sea-config.json \
  && cp "$(command -v node)" app-sea \
  && npx --yes postject@1.0.0-alpha.6 app-sea NODE_SEA_BLOB sea-prep.blob \
    --sentinel-fuse NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2 \
  && rm index.js sea-config.json sea-prep.blob

# For a non-relocatable executable, which the official glibc builds of Node.js are, postject moves the program header
# table to an address that is not 8 byte aligned. An earlier version of the injector crashed such processes at startup.
# Fail the build if that is no longer the case, since the test set would then no longer test this. The position-
# independent musl builds keep their program header table in place, so this only applies to glibc.
RUN if [ ! -e /lib/ld-musl-$(uname -m).so.1 ]; then \
      node -e ' \
        const phoff = require("node:fs").readFileSync("app/app-sea").readBigUInt64LE(0x20); \
        if (phoff % 8n === 0n) { \
          console.error(`Error: the program header table of app/app-sea is aligned (e_phoff=${phoff}).`); \
          process.exit(1); \
        }'; \
    fi

COPY injector-integration-tests/scripts/*.sh scripts/
COPY injector-integration-tests/tests/*.tests tests/
COPY injector-integration-tests/common/ common/
COPY injector-integration-tests/common/injector.custom-location.conf /custom/config/path/injector.conf

RUN scripts/create-config-file-directory.sh
RUN ${create_sdk_dummy_files_script}

COPY dist/${injector_binary} /injector/libotelinject.so

USER node
CMD ["scripts/run-tests-within-container.sh"]
