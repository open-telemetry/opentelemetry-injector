#!/usr/bin/env sh
# shellcheck disable=SC2059

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

set -euo noglob

home_directory=$(pwd)

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

# Runs one test case. Usage:
#
#   run_test_case $test_case_label $working_dir $test_app_command $expected_output $env_vars
#
# - test_case_label: a human readable phrase describing the test case
# - working_dir: the working directory for the test case
# - test_app_command: the test app executable to run, plus (optionally) additional command line arguments that will be passed on to
#   the test app
# - expected_output: The app's output will be compared to this string, the test case is deemed successful if the exit
#   code is zero and the app's output matches this string
# - env_vars (optional): Set additional environment variables like NODE_OPTIONS or OTEL_RESOURCE_ATTRIBUTES when running
#   the test
# shellcheck disable=SC2317
run_test_case() {
  test_case_label=$1
  working_dir=$2
  test_app_command=$3
  expected=$4
  env_vars=${5:-}

  if [ -n "${TEST_CASES:-}" ]; then
    # Only run test case if there is an _exact match_ for the test case label in the comma-separated list $TEST_CASES.
    IFS=,
    # shellcheck disable=SC2086
    set -- $TEST_CASES""

    run_this_test_case="false"
    for selected_test_case in "$@"; do
      if [ "$test_case_label" = "$selected_test_case" ]; then
        run_this_test_case="true"
      fi
    done
    if [ "$run_this_test_case" != "true" ]; then
      echo "- skipping test case \"$test_case_label\""
      return
    fi
  fi
  if [ -n "${TEST_CASES_CONTAINING:-}" ]; then
    # Only run test case if the test case label contains one of the strings from the comma-separated list
    # $TEST_CASES_CONTAINING as a substring.
    IFS=,
    # shellcheck disable=SC2086
    set -- $TEST_CASES_CONTAINING""
    run_this_test_case="false"
    for selected_test_case in "$@"; do
      set +e
      match=$(expr "$test_case_label" : ".*$selected_test_case.*")
      set -e
      if [ "$match" -gt 0 ]; then
        run_this_test_case="true"
      fi
    done
    if [ "$run_this_test_case" != "true" ]; then
      echo "- skipping test case \"$test_case_label\""
      return
    fi
  fi

  set +e
  match=$(expr "$test_case_label" : ".*default configuration file.*")
  set -e
  if [ "$match" -gt 0 ]; then
    echo "providing configuration file at default location /etc/opentelemetry/otelinject.conf for test case \"$test_case_label\""
    cp otelinject.conf /etc/opentelemetry/otelinject.conf
  fi

  set +e
  match=$(expr "$test_case_label" : ".*env file.*")
  set -e
  if [ "$match" -gt 0 ]; then
    echo "providing env file at /etc/opentelemetry/default_auto_instrumentation_env.conf for test case \"$test_case_label\""
    cp default_auto_instrumentation_env.conf /etc/opentelemetry/default_auto_instrumentation_env.conf
  else
    echo "providing empty env file at /etc/opentelemetry/default_auto_instrumentation_env.conf for test case \"$test_case_label\""
    touch /etc/opentelemetry/default_auto_instrumentation_env.conf
  fi

  cd "$working_dir"
  full_command="LD_PRELOAD=""$injector_binary"" OTEL_INJECTOR_K8S_NAMESPACE_NAME=my-namespace OTEL_INJECTOR_K8S_POD_NAME=my-pod OTEL_INJECTOR_K8S_POD_UID=275ecb36-5aa8-4c2a-9c47-d8bb681b9aff OTEL_INJECTOR_K8S_CONTAINER_NAME=test-app"
  if [ "${VERBOSE:-}" = "true" ]; then
    # add OTEL_INJECTOR_LOG_LEVEL=debug to the list of env vars to see debug output from the injector.
    full_command="$full_command OTEL_INJECTOR_LOG_LEVEL=debug"
  fi
  if [ "$env_vars" != "" ]; then
    full_command=" $full_command $env_vars"
  fi
  full_command=" $full_command $test_app_command"
  set +e
  test_output=$(eval "$full_command")
  test_exit_code=$?
  cd "$home_directory"
  set -e
  if [ $test_exit_code != 0 ]; then
    printf "${RED}test \"%s\" crashed:${NC}\n" "$test_case_label"
    echo "test command: $full_command"
    echo "received exit code: $test_exit_code"
    echo "output: $test_output"
    echo "--- end of output"
    exit_code=1
  elif [ "$test_output" != "$expected" ]; then
    printf "${RED}test \"%s\" failed:${NC}\n" "$test_case_label"
    echo "test command: $full_command"
    echo "expected: $expected"
    echo "actual:   $test_output"
    echo "--- end of output"
    exit_code=1
  else
    printf "${GREEN}test \"%s\" successful${NC}\n" "$test_case_label"
    if [ "${VERBOSE:-}" = "true" ]; then
      echo "test command: $full_command"
      echo "output: $test_output"
      echo "--- end of output"
    fi
  fi
}

exit_code=0

# shellcheck source=test/scripts/default.tests
. "scripts/${TEST_SET:-default.tests}"

exit $exit_code

