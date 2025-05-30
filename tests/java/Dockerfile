ARG BASE=busybox
FROM $BASE

COPY Main.java .

RUN javac Main.java && \
    jar cfe Main.jar Main Main.class

COPY otelinject.conf /etc/opentelemetry/otelinject/java.conf

CMD java -jar Main.jar

ENV OTEL_SERVICE_NAME iknowmyownservicename

ENV ANOTHER_VAR foo

COPY libotelinject.so /usr/lib/opentelemetry/libotelinject.so

RUN echo /usr/lib/opentelemetry/libotelinject.so >> /etc/ld.so.preload
