FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:8.0 AS build
ARG TARGETARCH
WORKDIR /source

# copy csproj and restore as distinct layers
COPY *.csproj .
RUN dotnet restore -a ${TARGETARCH}

# copy and publish app and libraries
COPY . .
RUN dotnet publish -a $TARGETARCH --no-restore -o /app

# final stage/image
FROM mcr.microsoft.com/dotnet/runtime:8.0
WORKDIR /app
COPY --from=build /app .

COPY otelinject.conf /etc/opentelemetry/otelinject/dotnet.conf

COPY libotelinject.so /usr/lib/opentelemetry/libotelinject.so
ENV OTEL_SERVICE_NAME iknowmyownservicename

ENV ANOTHER_VAR foo

RUN echo /usr/lib/opentelemetry/libotelinject.so >> /etc/ld.so.preload

CMD dotnet dotnetapp.dll