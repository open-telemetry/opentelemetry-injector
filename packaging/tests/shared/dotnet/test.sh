#!/bin/bash

dotnet DotNetTestApp.dll &

# If the .NET process is instrumented successfully, we should see a log report:
# InstrumentationScope System.Net.Http  in the collector's log output.
expected_log_line="InstrumentationScope System.Net.Http"

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
