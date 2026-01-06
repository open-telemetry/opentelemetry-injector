#!/usr/bin/env bash
# shellcheck disable=SC2059

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

set -eu

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

cd "$(dirname "${BASH_SOURCE[0]}")"/../..

if ! docker info > /dev/null 2>&1; then
  echo "This script uses docker, but it looks like Docker is not running. Please start docker and try again."
  exit 1
fi

architectures=""
if [[ -n "${ARCHITECTURES:-}" ]]; then
  architectures=("${ARCHITECTURES//,/ }")
  echo Only testing a subset of architectures: "${architectures[@]}"
fi

libc_flavors=""
if [[ -n "${LIBC_FLAVORS:-}" ]]; then
  libc_flavors=("${LIBC_FLAVORS//,/ }")
  echo Only testing a subset of libc flavors: "${libc_flavors[@]}"
fi

all_test_sets_string=$(find test/scripts/ -name \*.tests -print0 | xargs -0 -n 1 basename | sort | tr '\n' ' ')
read -ra all_test_sets <<< "$all_test_sets_string"
echo Found test sets: "${all_test_sets[@]}"

test_sets=""
if [[ -n "${TEST_SETS:-}" ]]; then
  test_sets=("${TEST_SETS//,/ }")
  echo Only running a subset of test sets: "${test_sets[@]}"
  for test_set_id in "${test_sets[@]}"; do
    test_set_file_name="test/scripts/$test_set_id.tests"
    if [[ ! -f "$test_set_file_name" ]]; then
      echo "Error: test set \"$test_set_id\" does not exist. Available test sets are: ${all_test_sets_string//\.tests/}"
      exit 1
    fi
  done
fi

if [[ -n "${TEST_CASES:-}" && -n "${TEST_CASES_CONTAINING:-}"  ]]; then
  echo "Error: TEST_CASES and TEST_CASES_CONTAINING are mutually exclusive, please set at most one of them."
  exit 1
fi

if [[ -n "${TEST_CASES:-}" ]]; then
  echo Only running a subset of test cases: "$TEST_CASES"
else
  TEST_CASES=""
fi

if [[ -n "${TEST_CASES_CONTAINING:-}" ]]; then
  echo Only running test cases which contain: "$TEST_CASES_CONTAINING"
else
  TEST_CASES_CONTAINING=""
fi

global_exit_code=0
test_exit_code_last_test_set=0
summary=""

run_test_set_for_architecture_and_libc_flavor() {
  arch=$1
  libc=$2
  test_set=$3
  echo
  echo "running test set \"$test_set\" on $arch and $libc"
  set +e
  ARCH="$arch" \
    LIBC="$libc" \
    TEST_SET="$test_set" \
    TEST_CASES="$TEST_CASES" \
    TEST_CASES_CONTAINING="$TEST_CASES_CONTAINING" \
    test/scripts/run-tests-for-container.sh
  test_exit_code_last_test_set=$?
  set -e
  echo
  echo ----------------------------------------
}

run_tests_for_architecture_and_libc_flavor() {
  arch=$1
  libc=$2
  echo
  echo ----------------------------------------
  echo "testing the injector library on $arch and $libc"
  echo ----------------------------------------

  test_exit_code=0
  for test_set in "${all_test_sets[@]}"; do
    local test_set_name="${test_set%.tests}"
    if [[ -n "${test_sets[0]}" ]]; then
      if [[ $(echo "${test_sets[@]}" | grep -o "$test_set_name" | wc -w) -eq 0 ]]; then
        echo "skipping test set $test_set"
        continue
      fi
    fi

    run_test_set_for_architecture_and_libc_flavor "$arch" "$libc" "$test_set"
    if [[ $test_exit_code_last_test_set -gt $test_exit_code ]]; then
      test_exit_code=$test_exit_code_last_test_set
    fi
  done

  echo
  echo ----------------------------------------
  if [ $test_exit_code != 0 ]; then
    printf "${RED}tests for %s/%s failed (see above for details)${NC}\n" "$arch" "$libc"
    global_exit_code=1
    summary="$summary\n$arch/$libc:\t${RED}failed${NC}"
  else
    printf "${GREEN}tests for %s/%s were successful${NC}\n" "$arch" "$libc"
    summary="$summary\n$arch/$libc:\t${GREEN}ok${NC}"
  fi
  echo ----------------------------------------
  echo
}

declare -a all_architectures=(
  "arm64"
  "amd64"
)
declare -a all_libc_flavors=(
  "glibc"
  "musl"
)

# build injector binary for both architectures
echo ----------------------------------------
echo building the injector binary locally from source
echo ----------------------------------------
for arch in "${all_architectures[@]}"; do
  if [[ -n "${architectures[0]}" ]]; then
    if [[ $(echo "${architectures[@]}" | grep -o "$arch" | wc -w) -eq 0 ]]; then
      echo ----------------------------------------
      echo "skipping build for CPU architecture $arch"
      echo ----------------------------------------
      continue
    fi
  fi

  make ARCH="$arch" dist
done
echo

for arch in "${all_architectures[@]}"; do
  if [[ -n "${architectures[0]}" ]]; then
    if [[ $(echo "${architectures[@]}" | grep -o "$arch" | wc -w) -eq 0 ]]; then
      echo ----------------------------------------
      echo "skipping tests on CPU architecture $arch"
      echo ----------------------------------------
      continue
    fi
  fi
  for libc_flavor in "${all_libc_flavors[@]}"; do
    if [[ -n "${libc_flavors[0]}" ]]; then
      if [[ $(echo "${libc_flavors[@]}" | grep -o "$libc_flavor" | wc -w) -eq 0 ]]; then
        echo ----------------------------------------
        echo "skipping tests for libc flavor $libc_flavor"
        echo ----------------------------------------
        continue
      fi
    fi
    run_tests_for_architecture_and_libc_flavor "$arch" "$libc_flavor"
  done
done

printf "$summary\n\n"
exit $global_exit_code
