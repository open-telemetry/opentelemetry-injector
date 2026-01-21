#!/usr/bin/env sh
# shellcheck disable=SC2059

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

set -eu

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

injector_binary=/injector/libotelinject.so
if [ ! -f $injector_binary ]; then
  printf "${RED}error: %s does not exist, not running any tests.${NC}\n" "$injector_binary"
  exit 1
fi

exit_code=0

# shellcheck source=injector-integration-tests/tests/binary-validation.tests
. "tests/binary-validation.tests"

exit $exit_code
