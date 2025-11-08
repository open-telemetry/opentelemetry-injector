FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build
WORKDIR /src
COPY "packaging/tests/shared/dotnet/DotNetTestApp.csproj" .
RUN dotnet restore "DotNetTestApp.csproj"
COPY "packaging/tests/shared/dotnet/*.cs" .
RUN dotnet build "DotNetTestApp.csproj" -c Release -o /app/build

FROM build AS publish
RUN dotnet publish "DotNetTestApp.csproj" -c Release -o /app/publish

FROM fedora:41 AS final

ARG ARCH=amd64
ARG RPM_ARCH=x86_64

ENV LANG=C.UTF-8

RUN dnf -y update && \
    dnf -y install wget dotnet-sdk-9.0 dotnet-runtime-9.0 && \
    dnf clean all

# TODO The otel collector version needs to be kept up to date, potentially with renovate.
RUN wget https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.128.0/otelcol-contrib_0.128.0_linux_${ARCH}.rpm
RUN rpm -i otelcol-contrib_0.128.0_linux_${ARCH}.rpm

COPY instrumentation/dist/*${RPM_ARCH}.rpm injector.rpm

RUN rpm -i injector.rpm

RUN echo /usr/lib/opentelemetry/libotelinject.so >> /etc/ld.so.preload

COPY --from=publish /app/publish .
COPY packaging/tests/shared/dotnet/test.sh test.sh

CMD ["./test.sh"]