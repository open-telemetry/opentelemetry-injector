FROM mcr.microsoft.com/dotnet/sdk:10.0@sha256:e362a8dbcd691522456da26a5198b8f3ca1d7641c95624fadc5e3e82678bd08a AS build
WORKDIR /src
COPY "packaging/tests/shared/dotnet/DotNetTestApp.csproj" .
RUN dotnet restore "DotNetTestApp.csproj"
COPY "packaging/tests/shared/dotnet/*.cs" .
RUN dotnet build "DotNetTestApp.csproj" -c Release -o /app/build

FROM build AS publish
RUN dotnet publish "DotNetTestApp.csproj" -c Release -o /app/publish

FROM fedora:45@sha256:af8cdc432037f5e8e288bbc26c2b55b96000a911ec5b37959cd464d830f6cc5b AS final

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