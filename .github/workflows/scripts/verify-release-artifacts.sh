#!/usr/bin/env bash

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

artifact_dir="${1:-artifacts}"
mapfile -d '' artifacts < <(find "${artifact_dir}" -type f -name 'libotelinject_*.so' -print0)

if (( ${#artifacts[@]} == 0 )); then
  echo "No release artifacts found to verify in ${artifact_dir}."
  exit 1
fi

if [[ -n "${COSIGN_PUBLIC_KEY:-}" ]]; then
  # CI signs with an ephemeral key without uploading to a transparency log.
  verification_args=(--key "${COSIGN_PUBLIC_KEY}" --insecure-ignore-tlog)
else
  : "${CERTIFICATE_IDENTITY:?CERTIFICATE_IDENTITY must be set for keyless verification}"
  : "${CERTIFICATE_OIDC_ISSUER:?CERTIFICATE_OIDC_ISSUER must be set for keyless verification}"
  verification_args=(
    --certificate-identity "${CERTIFICATE_IDENTITY}"
    --certificate-oidc-issuer "${CERTIFICATE_OIDC_ISSUER}"
  )
fi

for artifact in "${artifacts[@]}"; do
  bundle="${artifact}.sigstore.json"
  if [[ ! -f "${bundle}" ]]; then
    echo "Missing Sigstore bundle for ${artifact}."
    exit 1
  fi

  cosign verify-blob "${artifact}" \
    --bundle "${bundle}" \
    "${verification_args[@]}"
done
