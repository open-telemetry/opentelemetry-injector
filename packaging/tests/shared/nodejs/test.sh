#!/bin/bash

cd my_express_app
node app.js &
nodepid=$!
loop=0

function stop()
{
  kill $nodepid
  loop=1
  echo "Good bye"
}

function call()
{
  while [ $loop -eq 0 ]; do
    wget -q http://localhost:3000
    sleep 1
  done
}

trap stop SIGINT

call &

# If the Express process is instrumented successfully, we should see a log report:
# InstrumentationScope @opentelemetry/instrumentation-net in the collector's log output.
expected_log_line="@opentelemetry/instrumentation-net"

otelcol-contrib --config /etc/otelcol-contrib/config.yaml &> output.log &
until (( count++ >= 5 ));
do
  grep "$expected_log_line" output.log && echo && echo "Test successful, the expected string \"$expected_log_line\" has been found in the collector's log output." && exit 0
  sleep 4
done

echo
echo "Test failed: The expected log \"$expected_log_line\" has not been found in the collector's log output."
cat output.log
exit 1
