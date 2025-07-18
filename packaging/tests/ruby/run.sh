#!/bin/bash

set -e

SCRIPT_DIR="$( cd "$( dirname ${BASH_SOURCE[0]} )" && pwd )"
cd $SCRIPT_DIR/../../..
pwd
docker build -t instrumentation-ruby -f packaging/tests/ruby/Dockerfile .
docker run --rm -it instrumentation-ruby