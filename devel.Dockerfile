FROM debian:12@sha256:0d8498a0e9e6a60011df39aab78534cfe940785e7c59d19dfae1eb53ea59babe

RUN apt-get update && \
    apt-get install -y build-essential gdb default-jre tmux rsyslog

# to see syslogs, run the following in the container
# apt install rsyslog
# service rsyslog start

WORKDIR /instr
