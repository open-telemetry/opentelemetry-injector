#!/usr/bin/env bash

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

artifact_dir="${1:-artifacts}"
mapfile -d '' artifacts < <(find "${artifact_dir}" -type f -name 'libotelinject_*.so' -print0)

if (( ${#artifacts[@]} == 0 )); then
  echo "No release artifacts found to sign in ${artifact_dir}."
  exit 1
fi

sign_args=(--yes)
if [[ -n "${COSIGN_KEY:-}" ]]; then
  : "${COSIGN_SIGNING_CONFIG:?COSIGN_SIGNING_CONFIG must be set when COSIGN_KEY is used}"
  sign_args+=(
    --key "${COSIGN_KEY}"
    --signing-config "${COSIGN_SIGNING_CONFIG}"
  )
fi

for artifact in "${artifacts[@]}"; do
  cosign sign-blob "${sign_args[@]}" \
    --bundle "${artifact}.sigstore.json" \
    "${artifact}"
done
