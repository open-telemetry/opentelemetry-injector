ARG BASE=busybox
FROM $BASE

COPY main.rb .

RUN mkdir -p /etc/opentelemetry/otelinject

COPY otelinject.conf /etc/opentelemetry/otelinject/ruby.conf

CMD ruby main.rb

COPY libotelinject.so /usr/lib/opentelemetry/libotelinject.so

RUN echo /usr/lib/opentelemetry/libotelinject.so >> /etc/ld.so.preload
