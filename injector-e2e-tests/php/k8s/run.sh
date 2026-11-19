#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# The same chain the Docker end-to-end tests cover, but in Kubernetes: a stock php:8.3-apache
# image with nothing OpenTelemetry-related in it, instrumented by the injector and
# opentelemetry-php-distro delivered through an init container into an emptyDir, with the
# injector configured by a ConfigMap. That is the shape an operator's mutating webhook produces.
#
# Asserts that spans reach an in-cluster collector, that they came from the Apache SAPI rather
# than from some other PHP process, and that the injector contributed the Kubernetes resource
# attributes.
#
# Usage: run.sh          (creates the kind cluster if it does not exist)
#        run.sh --clean  (deletes the cluster and exits)

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
repo_root="$(cd ../../.. && pwd)"
cluster=php-injector-poc

if [[ "${1:-}" == "--clean" ]]; then
  kind delete cluster --name "$cluster"
  exit 0
fi

if [[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]]; then arch=arm64; else arch=amd64; fi

for required in "${repo_root}/dist/libotelinject_${arch}.so" \
  "${repo_root}/dist/php/glibc/distro/opentelemetry_php_distro_loader.so"; do
  if [[ ! -e "$required" ]]; then
    echo "missing prerequisite: $required" >&2
    echo "run 'make dist php-artifacts' first" >&2
    exit 1
  fi
done

if ! kind get clusters 2> /dev/null | grep -qx "$cluster"; then
  echo "==> creating kind cluster ${cluster}"
  kind create cluster --name "$cluster" --wait 120s || exit 1
fi
kubectl config use-context "kind-${cluster}" > /dev/null || exit 1

echo "==> building images"
docker build -q -t php-poc/artifacts:dev --build-arg "ARCH=${arch}" \
  -f Dockerfile.artifacts "$repo_root" > /dev/null || exit 1
docker build -q -t php-poc/app:dev -f Dockerfile.app "$repo_root" > /dev/null || exit 1

echo "==> loading images into the cluster"
kind load docker-image --name "$cluster" php-poc/artifacts:dev php-poc/app:dev > /dev/null || exit 1

echo "==> applying manifests"
kubectl apply -f manifests.yaml > /dev/null || exit 1
# Restart the app so a re-run picks up freshly loaded images rather than the previous pod.
kubectl -n php-poc rollout restart deploy/php-app > /dev/null 2>&1
kubectl -n php-poc rollout status deploy/collector --timeout=120s || exit 1
kubectl -n php-poc rollout status deploy/php-app --timeout=180s || exit 1

# Read the collector from here on, so spans produced before this point cannot satisfy the
# assertions below.
offset=$(($(kubectl -n php-poc logs deploy/collector 2> /dev/null | wc -l) + 1))

echo "==> generating traffic"
# A rollout can report success before the Service has endpoints, in which case an immediate
# request never reaches PHP and the run fails for a reason that has nothing to do with the
# injector. Retry until the application actually answers.
response="$(kubectl -n php-poc run "curl-$$" --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  -sS --retry 10 --retry-all-errors --retry-delay 2 --fail \
  http://php-app.php-poc.svc.cluster.local/ 2> /dev/null)"
printf 'APP| %s\n' "${response//$'\n'/$'\n'APP| }"
if ! grep -q "php-injector-poc ok" <<< "$response"; then
  echo "FAIL -- the application never answered; nothing to assert on"
  exit 1
fi

echo "==> waiting for spans"
spans=""
for _ in $(seq 1 20); do
  spans="$(kubectl -n php-poc logs deploy/collector 2> /dev/null | tail -n "+${offset}")"
  grep -q "ResourceSpans" <<< "$spans" && break
  sleep 2
done

problem=""
if ! grep -q "ResourceSpans" <<< "$spans"; then
  problem="no spans reached the collector"
elif ! grep -q "telemetry.distro.name: Str(opentelemetry-php-distro)" <<< "$spans"; then
  problem="spans arrived but were not produced by the PHP distro"
elif ! grep -q "service.name: Str(php-app)" <<< "$spans"; then
  problem="the injector did not set service.name from the pod label"
elif ! grep -q "k8s.pod.name" <<< "$spans" || ! grep -q "k8s.namespace.name" <<< "$spans"; then
  problem="the injector did not add Kubernetes resource attributes"
elif ! grep -q "process.runtime.name: Str(apache2handler)" <<< "$spans"; then
  problem="no span came from the Apache SAPI"
elif ! grep -q "Name           : GET /" <<< "$spans"; then
  problem="the HTTP request produced no server span"
elif ! grep -q "http.response.status_code: Int(200)" <<< "$spans"; then
  problem="the server span carries no HTTP semantic attributes"
fi

echo "==> collector received:"
sed -n '/ResourceSpans/,$p' <<< "$spans" | head -40

echo
if [[ -n "$problem" ]]; then
  echo "FAIL -- ${problem}"
  exit 1
fi
echo "ok -- stock PHP image instrumented in-cluster, spans received with Kubernetes resource attributes"
echo "     (delete the cluster with: $0 --clean)"
