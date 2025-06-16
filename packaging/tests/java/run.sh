#!/bin/bash

set -e

SCRIPT_DIR="$( cd "$( dirname ${BASH_SOURCE[0]} )" && pwd )"
cd $SCRIPT_DIR/../../..
docker build -t instrumentation-java -f packaging/tests/java/Dockerfile .
docker run --rm -it instrumentation-java