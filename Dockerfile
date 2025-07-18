ARG DOCKER_REPO=docker.io
FROM ${DOCKER_REPO}/debian:12@sha256:d42b86d7e24d78a33edcf1ef4f65a20e34acb1e1abd53cabc3f7cdf769fc4082

RUN apt-get update && \
    apt-get install -y build-essential

WORKDIR /libotelinject

COPY src /libotelinject/src
COPY Makefile /libotelinject/Makefile
