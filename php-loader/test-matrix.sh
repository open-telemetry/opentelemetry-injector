#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# Milestone A1: prove that ONE loader binary per libc is accepted by every
# supported PHP -- across minor versions, NTS/ZTS and glibc/musl -- and that it
# correctly reports the host's module API and thread-safety flavor.
#
# This is the assumption the whole universal-loader design rests on, so it is
# checked directly rather than inferred from the fact that it compiled.
#
# Usage: test-matrix.sh [arch]   (default: the host architecture)

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
repo_root="$(cd .. && pwd)"

if [[ "${1:-}" != "" ]]; then
  arch="$1"
elif [[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]]; then
  arch="arm64"
else
  arch="amd64"
fi

# PHP minor -> the module API number it must report. From php-src release tags;
# these are the artifact directory keys, so a mismatch here is a real failure
# and not a cosmetic one.
expected_api_for() {
  case "$1" in
    8.1) echo 20210902 ;;
    8.2) echo 20220829 ;;
    8.3) echo 20230831 ;;
    8.4) echo 20240924 ;;
    8.5) echo 20250925 ;;
    *) echo "" ;;
  esac
}

# The loader is installed at <root>/<libc>/otel_loader.so, because it recovers
# the libc flavor from its own path.
container_root=/opt/otel/php

passed=0
failed=0
skipped=0
failures=()

run_case() {
  local php_version="$1" libc="$2" ts="$3" image="$4"
  local label="php ${php_version} ${libc} ${ts}"
  local host_so="${repo_root}/dist/php/${libc}/${arch}/otel_loader.so"

  if [[ ! -f "$host_so" ]]; then
    echo "SKIP  ${label}  (no loader built at dist/php/${libc}/${arch})"
    skipped=$((skipped + 1))
    return
  fi

  if ! docker image inspect "$image" > /dev/null 2>&1; then
    if ! docker pull --platform "linux/${arch}" "$image" > /dev/null 2>&1; then
      echo "SKIP  ${label}  (image ${image} unavailable)"
      skipped=$((skipped + 1))
      return
    fi
  fi

  local output
  output="$(docker run --rm --platform "linux/${arch}" \
    -v "${host_so}:${container_root}/${libc}/otel_loader.so:ro" \
    -e OTEL_PHP_LOADER_LOG_LEVEL=debug \
    "$image" \
    php -d "zend_extension=${container_root}/${libc}/otel_loader.so" \
    -r 'echo "APP_RAN\n";' 2>&1)"
  local exit_code=$?

  local expected_api expected_ts
  expected_api="$(expected_api_for "$php_version")"
  if [[ "$ts" == "zts" ]]; then expected_ts="ZTS"; else expected_ts="NTS"; fi

  local problem=""
  if [[ $exit_code -ne 0 ]]; then
    problem="php exited ${exit_code}"
  elif ! grep -q "APP_RAN" <<< "$output"; then
    problem="the application did not run"
  elif grep -qi "Cannot load\|doesn't appear to be a valid Zend extension\|requires Zend Engine API" <<< "$output"; then
    problem="the engine refused the extension"
  elif ! grep -q "module API ${expected_api}" <<< "$output"; then
    problem="expected module API ${expected_api}, got: $(grep -o 'module API [0-9]*' <<< "$output" | head -1)"
  elif ! grep -q "build_id_check.*${expected_ts}" <<< "$output"; then
    problem="expected thread safety ${expected_ts}"
  fi

  if [[ -n "$problem" ]]; then
    echo "FAIL  ${label}  -- ${problem}"
    failures+=("${label}: ${problem}")
    if [[ "${VERBOSE:-}" == "true" ]]; then
      printf '        %s\n' "${output//$'\n'/$'\n'        }"
    fi
    failed=$((failed + 1))
  else
    echo "ok    ${label}  (module API ${expected_api}, ${expected_ts})"
    passed=$((passed + 1))
  fi
}

echo "loader matrix, arch=${arch}"
echo

for php_version in 8.1 8.2 8.3 8.4 8.5; do
  run_case "$php_version" glibc non-zts "php:${php_version}-cli"
  run_case "$php_version" glibc zts "php:${php_version}-zts"
  run_case "$php_version" musl non-zts "php:${php_version}-cli-alpine"
  run_case "$php_version" musl zts "php:${php_version}-zts-alpine"
done

echo
echo "passed: ${passed}, failed: ${failed}, skipped: ${skipped}"
if [[ $failed -gt 0 ]]; then
  echo
  echo "failures:"
  printf '  %s\n' "${failures[@]}"
  exit 1
fi
