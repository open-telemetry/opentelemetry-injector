ARG DOCKER_REPO=docker.io
FROM ${DOCKER_REPO}/debian:12

RUN apt-get update && \
    apt-get install -y build-essential

WORKDIR /libotelinject

COPY src /libotelinject/src
COPY Makefile /libotelinject/Makefile
