ARG DOCKER_REPO=docker.io
FROM ${DOCKER_REPO}/debian:13@sha256:6d87375016340817ac2391e670971725a9981cfc24e221c47734681ed0f6c0f5

RUN apt-get update && \
    apt-get install -y build-essential

WORKDIR /libotelinject

COPY src /libotelinject/src
COPY Makefile /libotelinject/Makefile
