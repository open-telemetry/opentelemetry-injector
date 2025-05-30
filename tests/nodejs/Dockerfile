ARG BASE=busybox
FROM $BASE

COPY index.js .

RUN mkdir -p /etc/opentelemetry/otelinject

COPY otelinject.conf /etc/opentelemetry/otelinject/node.conf

CMD node index.js

COPY libotelinject.so /usr/lib/opentelemetry/libotelinject.so

RUN echo /usr/lib/opentelemetry/libotelinject.so >> /etc/ld.so.preload
