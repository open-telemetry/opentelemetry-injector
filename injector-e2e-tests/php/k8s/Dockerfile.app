# A stock PHP image with an application in it and nothing else. No OpenTelemetry package, no
# extension, no ini -- that is the point of the test.
FROM php:8.3-apache
COPY injector-e2e-tests/php/k8s/index.php /var/www/html/index.php
