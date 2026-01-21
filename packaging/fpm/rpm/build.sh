#!/bin/bash

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# shellcheck disable=SC1091 # Including common.sh
. "$SCRIPT_DIR/../common.sh"

VERSION="${1:-}"
ARCH="${2:-amd64}"
OUTPUT_DIR="${3:-$REPO_DIR/instrumentation/dist}"

if [[ -z "$VERSION" ]]; then
    VERSION="$( get_version )"
fi

# rpm doesn't like dashes in the version, replace with underscore
VERSION="${VERSION/'-'/'_'}"
VERSION="${VERSION#v}"

buildroot="$(mktemp -d)"

setup_files_and_permissions "$ARCH" "$buildroot"

mkdir -p "$OUTPUT_DIR"

if [[ "$ARCH" = "arm64" ]]; then
    ARCH="aarch64"
elif [[ "$ARCH" = "amd64" ]]; then
    ARCH="x86_64"
fi

sudo fpm -s dir -t rpm -n "$PKG_NAME" -v "$VERSION" -f -p "$OUTPUT_DIR" \
    --vendor "$PKG_VENDOR" \
    --maintainer "$PKG_MAINTAINER" \
    --description "$PKG_DESCRIPTION" \
    --license "$PKG_LICENSE" \
    --url "$PKG_URL" \
    --architecture "$ARCH" \
    --rpm-rpmbuild-define "_build_id_links none" \
    --rpm-summary "$PKG_DESCRIPTION" \
    --rpm-use-file-permissions \
    --before-remove "$PREUNINSTALL_PATH" \
    --depends sed \
    --depends grep \
    --config-files "$CONFIG_DIR_INSTALL_PATH" \
    "$buildroot/"=/

if [[ "${LIST_PACKAGE_CONTENTS_AFTER_BUILD:-}" == "true" ]]; then
  rpm -qpli "${OUTPUT_DIR}/${PKG_NAME}-${VERSION}-1.${ARCH}.rpm"
fi
