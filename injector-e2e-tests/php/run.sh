#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# End-to-end tests of the complete chain -- injector -> PHP_INI_SCAN_DIR -> loader ->
# opentelemetry.so -> SDK bootstrap -> spans arriving at a collector over OTLP -- against real
# PHP applications running under each supported SAPI.
#
# Every case asserts all of:
#   1. the application ran;
#   2. the application's own auto_prepend_file still ran -- enabling instrumentation must never
#      take that single-valued, last-ini-wins directive away from the application;
#   3. opentelemetry.so is loaded AND its hook API works, proven by a span the application never
#      created itself (an extension that loads but does not function would pass a mere
#      extension_loaded() check);
#   4. both spans left the process over OTLP and were received by a real collector, not just
#      printed by a console exporter inside the same process.
#
# Usage: run.sh [sapi ...]     (default: all)

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
repo_root="$(cd ../.. && pwd)"

if [[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]]; then arch=arm64; else arch=amd64; fi
libc=glibc
php_image="${PHP_IMAGE:-php:8.3-cli}"
module_api="${MODULE_API:-20230831}"

injector="${repo_root}/dist/libotelinject_${arch}.so"
loader="${repo_root}/dist/php/${libc}/${arch}/otel_loader.so"
artifacts="${repo_root}/dist/artifacts"

for required in "$injector" "$loader" "$artifacts/${module_api}/${libc}/non-zts/opentelemetry.so"; do
  if [[ ! -e "$required" ]]; then
    echo "missing prerequisite: $required" >&2
    echo "build it first (see README.md in this directory)" >&2
    exit 1
  fi
done

# The install tree the injector points at, assembled the way a distribution package would.
install_dir="${repo_root}/dist/e2e-install"
rm -rf "$install_dir"
mkdir -p "$install_dir/php/${libc}" "$install_dir/conf.d"
cp "$loader" "$install_dir/php/${libc}/otel_loader.so"
echo "zend_extension=/usr/lib/opentelemetry/php/${libc}/otel_loader.so" \
  > "$install_dir/php/${libc}/otel-loader.ini"
echo 'php_auto_instrumentation_agent_path_prefix = /usr/lib/opentelemetry/php' \
  > "$install_dir/conf.d/php.conf"

sapis=("$@")
if [[ ${#sapis[@]} -eq 0 ]]; then sapis=(cli builtin fpm apache); fi

# A real collector on a private network, so the assertions cover the wire format and transport
# rather than stopping at the SDK boundary.
network=otel-php-e2e-net
collector=otel-php-e2e-collector
collector_image="${COLLECTOR_IMAGE:-otel/opentelemetry-collector-contrib:0.137.0}"

cleanup() {
  docker rm -f "$collector" > /dev/null 2>&1 || true
  docker network rm "$network" > /dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

docker network create "$network" > /dev/null
docker run -d --name "$collector" --network "$network" \
  --platform "linux/${arch}" \
  -v "${PWD}/collector-config.yaml:/etc/otelcol-contrib/config.yaml:ro" \
  "$collector_image" > /dev/null
# The collector needs its OTLP listeners up before the first request, or the export is simply
# refused and the test fails for the wrong reason.
for _ in $(seq 1 30); do
  if docker logs "$collector" 2>&1 | grep -q "Everything is ready"; then break; fi
  sleep 1
done

image_for() {
  case "$1" in
    cli | builtin) echo "${php_image}" ;;
    fpm) echo "${php_image/-cli/-fpm}" ;;
    apache) echo "${php_image/-cli/-apache}" ;;
  esac
}

passed=0
failed=0
failures=()

for sapi in "${sapis[@]}"; do
  base="$(image_for "$sapi")"
  tag="otel-php-e2e-${sapi}"

  # --load is required, not optional: under the docker-container driver that CI's
  # setup-buildx-action installs, a plain `-t` build stays in the builder's cache and never
  # reaches the daemon, so the docker run below would silently find no image.
  if ! docker buildx build --platform "linux/${arch}" --load \
      --build-arg "PHP_IMAGE=${base}" --build-arg "SAPI=${sapi}" \
      -t "$tag" -f Dockerfile.sapi . > "/tmp/e2e-build-${sapi}.log" 2>&1; then
    echo "FAIL  ${sapi}  -- image build failed"
    printf '      %s\n' "$(tail -n 40 "/tmp/e2e-build-${sapi}.log")"
    failures+=("${sapi}: image build failed")
    failed=$((failed + 1))
    continue
  fi

  marker="span-check-${sapi}"
  collector_log_offset=$(( $(docker logs "$collector" 2>&1 | wc -l) + 1 ))

  output="$(docker run --rm --platform "linux/${arch}" \
    --network "$network" \
    -v "${injector}:/injector/libotelinject.so:ro" \
    -v "${install_dir}/php/${libc}:/usr/lib/opentelemetry/php/${libc}:ro" \
    -v "${artifacts}/${module_api}:/usr/lib/opentelemetry/php/${module_api}:ro" \
    -v "${install_dir}/conf.d:/etc/opentelemetry/injector/conf.d:ro" \
    -v "${PWD}/app:/app:ro" \
    -e LD_PRELOAD=/injector/libotelinject.so \
    -e OTEL_PHP_AUTOLOAD_ENABLED=true \
    -e OTEL_TRACES_EXPORTER=otlp \
    -e OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf \
    -e OTEL_EXPORTER_OTLP_ENDPOINT="http://${collector}:4318" \
    -e OTEL_METRICS_EXPORTER=none \
    -e OTEL_LOGS_EXPORTER=none \
    -e OTEL_SERVICE_NAME="${marker}" \
    "$tag" 2>&1)"
  run_exit=$?

  # Give the collector a moment to log what it received before reading its output back.
  sleep 2
  received="$(docker logs "$collector" 2>&1 | tail -n "+${collector_log_offset}")"

  problem=""
  if [[ $run_exit -ne 0 ]]; then
    problem="the container exited ${run_exit}"
  elif ! grep -q "APP_RAN" <<< "$output"; then
    problem="the application did not run"
  elif ! grep -q "OWN_PREPEND=ran" <<< "$output"; then
    problem="the application's own auto_prepend_file was displaced"
  elif ! grep -q "SDK_CONFIGURED=yes" <<< "$output"; then
    problem="the SDK autoload did not configure a tracer provider"
  elif ! grep -q "EXT_LOADED=yes" <<< "$output"; then
    problem="opentelemetry.so was not loaded"
  elif ! grep -q "HOOK_API=available" <<< "$output"; then
    problem="opentelemetry.so exposes no hook API"
  elif ! grep -q "service.name: Str(${marker})" <<< "$received"; then
    problem="the collector received no spans over OTLP"
  elif ! grep -q "Name           : e2e-span" <<< "$received"; then
    problem="the manually created span did not reach the collector"
  elif ! grep -q "Name           : auto-hooked-span" <<< "$received"; then
    problem="no hook-generated span reached the collector (the extension loaded but does not instrument)"
  fi

  if [[ -n "$problem" ]]; then
    echo "FAIL  ${sapi}  -- ${problem}"
    failures+=("${sapi}: ${problem}")
    # Always, not just under VERBOSE: a failure that cannot be diagnosed from the CI log costs a
    # whole round trip to reproduce.
    echo "      --- application output ---"
    printf '      %s\n' "${output//$'\n'/$'\n'      }"
    echo "      --- collector output ---"
    printf '      %s\n' "${received//$'\n'/$'\n'      }"
    failed=$((failed + 1))
  else
    echo "ok    ${sapi}  (manual + hooked spans received over OTLP, own auto_prepend_file intact)"
    passed=$((passed + 1))
  fi
done

echo
echo "passed: ${passed}, failed: ${failed}"
if [[ $failed -gt 0 ]]; then
  printf '  %s\n' "${failures[@]}"
  exit 1
fi
