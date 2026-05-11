# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

ARG base_image_build=mcr.microsoft.com/dotnet/sdk:9.0-bookworm-slim
ARG base_image_run=mcr.microsoft.com/dotnet/runtime:9.0-bookworm-slim

FROM ${base_image_build} AS build
ARG TARGETARCH

WORKDIR /no-op-startup-hook-source
COPY injector-integration-tests/apps/dotnet/no-op-startup-hook .
RUN dotnet restore
RUN dotnet publish --no-restore -o /no-op-startup-hook

WORKDIR /source
# copy csproj and restore as distinct layers
COPY injector-integration-tests/apps/dotnet/app/*.csproj .
RUN dotnet restore
# copy and publish app and libraries
COPY injector-integration-tests/apps/dotnet/app/* .
RUN dotnet publish --no-restore -o /app

# final stage/image
FROM ${base_image_run}

RUN mkdir -p /etc/opentelemetry/injector/conf.d && chmod -R 777 /etc/opentelemetry

WORKDIR /usr/src/otel/injector/
COPY --from=build /no-op-startup-hook no-op-startup-hook
COPY --from=build /app app

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
