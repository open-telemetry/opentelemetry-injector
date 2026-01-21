#!/usr/bin/env sh
# shellcheck disable=SC2059

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

set -eu

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

if [ -z "${EXPECTED_CPU_ARCHITECTURE:-}" ]; then
  echo "EXPECTED_CPU_ARCHITECTURE is not set for $0."
  exit 1
fi

arch=$(uname -m)
arch_exit_code=$?
if [ $arch_exit_code != 0 ]; then
  printf "${RED}verifying CPU architecture failed:${NC}\n"
  echo "exit code: $arch_exit_code"
  echo "output: $arch"
  exit 1
elif [ "$arch" != "$EXPECTED_CPU_ARCHITECTURE" ]; then
  printf "${RED}verifying CPU architecture failed:${NC}\n"
  echo "expected: $EXPECTED_CPU_ARCHITECTURE"
  echo "actual:   $arch"
  exit 1
else
  printf "verifying CPU architecture %s successful\n" "$EXPECTED_CPU_ARCHITECTURE"
fi

injector_binary=/injector/libotelinject.so
if [ ! -f $injector_binary ]; then
  printf "${RED}error: %s does not exist, not running any tests.${NC}\n" "$injector_binary"
  exit 1
fi

exit_code=0

# shellcheck source=injector-integration-tests/tests/binary-validation.tests
. "tests/binary-validation.tests"

exit $exit_code
