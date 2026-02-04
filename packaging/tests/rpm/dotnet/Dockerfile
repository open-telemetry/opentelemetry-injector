FROM mcr.microsoft.com/dotnet/sdk:10.0@sha256:6ba533cc61a5d8c5e7d4b3a3e33e2ddc2efef200b112e4d658303516bfd24255 AS build
WORKDIR /src
COPY "packaging/tests/shared/dotnet/DotNetTestApp.csproj" .
RUN dotnet restore "DotNetTestApp.csproj"
COPY "packaging/tests/shared/dotnet/*.cs" .
RUN dotnet build "DotNetTestApp.csproj" -c Release -o /app/build

FROM build AS publish
RUN dotnet publish "DotNetTestApp.csproj" -c Release -o /app/publish

FROM fedora:44@sha256:64de49837325632232088e59c20518565a9d657095f9f3c2fa6033a42fb1412b AS final

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