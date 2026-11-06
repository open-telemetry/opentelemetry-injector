#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# End-to-end tests of the complete chain -- injector -> PHP_INI_SCAN_DIR -> opentelemetry-php-distro
# loader -> per-version extension -> SDK bootstrap -> spans arriving at a collector over OTLP --
# against real PHP applications running under each supported SAPI.
#
# Every case asserts all of:
#   1. the application ran;
#   2. the application's own auto_prepend_file still ran -- enabling instrumentation must never
#      take that single-valued, last-ini-wins directive away from the application;
#   3. the distro's extension is loaded and its hook API is live;
#   4. a root span the application never wrote any code to create left the process over OTLP and
#      was received by a real collector -- the fixture contains no OpenTelemetry code at all, so a
#      span arriving is the only possible evidence that instrumentation actually works.
#
# Usage: run.sh [sapi ...]     (default: all)

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
repo_root="$(cd ../.. && pwd)"

if [[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]]; then arch=arm64; else arch=amd64; fi
libc=glibc
php_image="${PHP_IMAGE:-php:8.3-cli}"

injector="${repo_root}/dist/libotelinject_${arch}.so"
artifacts="${repo_root}/dist/php/${libc}"

for required in "$injector" "${artifacts}/otel-loader.ini" "${artifacts}/distro/opentelemetry_php_distro_loader.so"; do
  if [[ ! -e "$required" ]]; then
    echo "missing prerequisite: $required" >&2
    echo "build it first (see README.md in this directory)" >&2
    exit 1
  fi
done

# The injector's own drop-in, as a distribution package would install it.
install_dir="${repo_root}/dist/e2e-install"
rm -rf "$install_dir"
mkdir -p "$install_dir/conf.d"
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
  # PHP_SAPI as the distro reports it in process.runtime.name. Asserting on this is what proves the
  # span came from the SAPI under test rather than from some other PHP process in the container.
  case "$sapi" in
    cli) runtime_name=cli ;;
    builtin) runtime_name=cli-server ;;
    fpm) runtime_name=fpm-fcgi ;;
    apache) runtime_name=apache2handler ;;
    *) runtime_name="$sapi" ;;
  esac
  collector_log_offset=$(( $(docker logs "$collector" 2>&1 | wc -l) + 1 ))

  output="$(docker run --rm --platform "linux/${arch}" \
    --network "$network" \
    -v "${injector}:/injector/libotelinject.so:ro" \
    -v "${artifacts}:/usr/lib/opentelemetry/php/${libc}:ro" \
    -v "${artifacts}/distro:/opt/opentelemetry/php/distro:ro" \
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
  elif ! grep -q "EXT_LOADED=yes" <<< "$output"; then
    problem="the distro's extension was not loaded"
  elif ! grep -q "HOOK_API=available" <<< "$output"; then
    problem="the distro's extension exposes no hook API"
  elif ! grep -q "SDK_SCOPED=yes" <<< "$output"; then
    problem="the distro leaked unscoped SDK classes into the application's namespace"
  elif ! grep -q "service.name: Str(${marker})" <<< "$received"; then
    problem="the collector received no spans over OTLP"
  elif ! grep -q "telemetry.distro.name: Str(opentelemetry-php-distro)" <<< "$received"; then
    problem="spans arrived but were not produced by the PHP distro"
  elif ! grep -q "process.runtime.name: Str(${runtime_name})" <<< "$received"; then
    problem="no span came from the ${sapi} SAPI"
  elif ! grep -q "Kind           : Server" <<< "$received"; then
    problem="the distro produced no root span, so the application is not actually instrumented"
  elif [[ "$sapi" != "cli" ]] && ! grep -q "http.response.status_code: Int(200)" <<< "$received"; then
    problem="the server span carries no HTTP semantic attributes"
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
    echo "ok    ${sapi}  (distro root span received over OTLP, own auto_prepend_file intact)"
    passed=$((passed + 1))
  fi
done

echo
echo "passed: ${passed}, failed: ${failed}"
if [[ $failed -gt 0 ]]; then
  printf '  %s\n' "${failures[@]}"
  exit 1
fi
