#!/bin/bash

ruby main.rb &> /dev/null &

otelcol-contrib --config /etc/otelcol-contrib/config.yaml &> output.log &
until (( count++ >= 5 ));
do
  grep "org.apache.coyote" output.log && exit 0
  sleep 4
done
exit 1
