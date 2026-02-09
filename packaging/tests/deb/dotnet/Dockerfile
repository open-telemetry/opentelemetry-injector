FROM mcr.microsoft.com/dotnet/sdk:9.0@sha256:0d84f05256dec37a5d1739158fd5ea197b8ad3b4e8d0e32be47b754db5963a9e AS build
WORKDIR /src
COPY "packaging/tests/shared/dotnet/DotNetTestApp.csproj" .
RUN dotnet restore "DotNetTestApp.csproj"
COPY "packaging/tests/shared/dotnet/*.cs" .
RUN dotnet build "DotNetTestApp.csproj" -c Release -o /app/build

FROM build AS publish
RUN dotnet publish "DotNetTestApp.csproj" -c Release -o /app/publish

FROM debian:12@sha256:34e7f0ae7c10a61bfbef6e1b2ed205d9b47bb12e90c50696f729a5c7a01cf1f2 AS final

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