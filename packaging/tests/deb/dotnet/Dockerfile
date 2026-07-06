FROM mcr.microsoft.com/dotnet/sdk:10.0.301@sha256:ea8bde36c11b6e7eec2656d0e59101d4462f6bd630730f2c8201ed0572b295d5 AS build
WORKDIR /src
COPY "packaging/tests/shared/dotnet/DotNetTestApp.csproj" .
RUN dotnet restore "DotNetTestApp.csproj"
COPY "packaging/tests/shared/dotnet/*.cs" .
RUN dotnet build "DotNetTestApp.csproj" -c Release -o /app/build

FROM build AS publish
RUN dotnet publish "DotNetTestApp.csproj" -c Release -o /app/publish

FROM debian:trixie-20260623@sha256:d07d1b51c39f51188e60be9b64e6bf769fa94e187f092bc32b91305cfa34ba5a AS final

ARG ARCH=amd64
ARG RPM_ARCH=x86_64

ENV LANG=C.UTF-8

RUN apt-get update
RUN apt install -y  wget

RUN wget https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb -O packages-microsoft-prod.deb && \
    dpkg -i packages-microsoft-prod.deb && \
    rm packages-microsoft-prod.deb

RUN apt-get update

RUN apt-get install -y dotnet-runtime-9.0 dotnet-sdk-9.0

# TODO The otel collector version needs to be kept up to date, potentially with renovate.
RUN wget https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.128.0/otelcol-contrib_0.128.0_linux_${ARCH}.deb
RUN dpkg -i otelcol-contrib_0.128.0_linux_${ARCH}.deb

COPY instrumentation/dist/*${ARCH}.deb injector.deb

RUN dpkg -i injector.deb

RUN echo /usr/lib/opentelemetry/libotelinject.so >> /etc/ld.so.preload

COPY --from=publish /app/publish .
COPY packaging/tests/shared/dotnet/test.sh test.sh

CMD ["./test.sh"]