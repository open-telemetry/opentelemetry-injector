#!/bin/sh
# Starts the SAPI under test, drives one request through it, and prints the result so the
# harness can assert on a single stream. Each branch prints the application output and whatever
# the console span exporter produced, which land in different places per SAPI.
set -u

case "$SAPI" in
  cli)
    php /app/index.php 2>&1
    ;;

  builtin)
    php -S 127.0.0.1:8080 -t /app > /tmp/server.log 2>&1 &
    sleep 2
    curl -s http://127.0.0.1:8080/index.php
    # The console exporter writes to the worker's stdout, not the response body.
    cat /tmp/server.log
    ;;

  fpm)
    # catch_workers_output routes the worker's stdout (where the console exporter writes) into
    # the master's log instead of discarding it.
    printf '[global]\nerror_log = /tmp/fpm.log\n[www]\ncatch_workers_output = yes\nlisten = 127.0.0.1:9000\n' \
      > /usr/local/etc/php-fpm.d/zz-e2e.conf
    php-fpm -D 2>/dev/null
    nginx 2>/dev/null
    sleep 2
    curl -s http://127.0.0.1:8080/index.php
    cat /tmp/fpm.log 2>/dev/null
    ;;

  apache)
    # Under mod_php the console exporter writes into the response body, so the single curl
    # captures both the application output and the span.
    apache2-foreground > /tmp/apache.log 2>&1 &
    sleep 3
    curl -s http://127.0.0.1:80/index.php
    cat /tmp/apache.log
    ;;

  *)
    echo "unknown SAPI: $SAPI" >&2
    exit 1
    ;;
esac
