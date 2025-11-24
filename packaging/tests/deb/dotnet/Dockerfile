ARG ARCH=amd64

FROM mcr.microsoft.com/dotnet/sdk:9.0-bookworm-slim-${ARCH}

ENV LANG=C.UTF-8

WORKDIR /src
COPY "packaging/tests/shared/dotnet/DotNetTestApp.csproj" .
RUN dotnet restore "DotNetTestApp.csproj"
COPY "packaging/tests/shared/dotnet/*.cs" .
RUN dotnet build "DotNetTestApp.csproj" -c Release -o /app/build -r linux-${ARCH}

RUN dotnet publish "DotNetTestApp.csproj" -c Release -o /app/publish -r linux-${ARCH}

RUN apt-get update
RUN apt install -y  wget

# TODO The otel collector version needs to be kept up to date, potentially with renovate.
RUN wget https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.128.0/otelcol-contrib_0.128.0_linux_${ARCH}.deb
RUN dpkg -i otelcol-contrib_0.128.0_linux_${ARCH}.deb

COPY instrumentation/dist/*${ARCH}.deb injector.deb

RUN dpkg -i injector.deb

RUN echo /usr/lib/opentelemetry/libotelinject.so >> /etc/ld.so.preload

RUN cp /app/publish/* .
COPY packaging/tests/shared/dotnet/test.sh test.sh

CMD ["./test.sh"]