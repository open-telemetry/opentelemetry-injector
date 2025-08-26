#!/bin/bash

apache-tomcat/bin/startup.sh

# If the Tomcat process is instrumented successfully, we should see log lines like:
# InstrumentationScope org.apache.coyote.http11.Http11NioProtocol in the collector's log output.
expected_log_line="org.apache.coyote"

otelcol-contrib --config /etc/otelcol-contrib/config.yaml &> output.log &
until (( count++ >= 5 ));
do
  grep "$expected_log_line" output.log && echo && echo "Test successful, the expected string \"$expected_log_line\" has been found in the collector's log output." && exit 0
  sleep 4
done

echo
echo "Test failed: The expected log \"$expected_log_line\" has not been found in the collector's log output."
exit 1
