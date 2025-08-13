FROM debian:12@sha256:731dd1380d6a8d170a695dbeb17fe0eade0e1c29f654cf0a3a07f372191c3f4b

RUN apt-get update && \
    apt-get install -y build-essential gdb default-jre tmux rsyslog

# to see syslogs, run the following in the container
# apt install rsyslog
# service rsyslog start

WORKDIR /instr
