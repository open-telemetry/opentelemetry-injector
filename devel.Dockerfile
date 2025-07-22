FROM debian:12@sha256:b6507e340c43553136f5078284c8c68d86ec8262b1724dde73c325e8d3dcdeba

RUN apt-get update && \
    apt-get install -y build-essential gdb default-jre tmux rsyslog

# to see syslogs, run the following in the container
# apt install rsyslog
# service rsyslog start

WORKDIR /instr
