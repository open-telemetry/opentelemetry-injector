#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# Stages opentelemetry-php-distro in the layout the injector points PHP_INI_SCAN_DIR at:
#
#   dist/php/<libc>/otel-loader.ini      <- the only file the scan directory exposes
#   dist/php/<libc>/distro/...           <- the distro tree, as its package installs it
#
# The distro ships one universal loader (opentelemetry_php_distro_loader.so) plus the per-PHP
# extensions it dispatches to, so a single install serves PHP 8.1 through 8.5. We deliberately do
# not run the distro's post-install script: it discovers the host PHP and writes into each SAPI's
# conf.d, which is exactly the host-wide mutation the injector exists to avoid. Pointing
# PHP_INI_SCAN_DIR at an ini with the two documented lines achieves the same activation without
# touching the image.
#
# Usage: prepare-artifacts.sh [version]     (default: the version pinned below)

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
repo_root="$(cd ../.. && pwd)"

distro_version="${1:-${OTEL_PHP_DISTRO_VERSION:-0.7.0}}"
distro_repo="open-telemetry/opentelemetry-php-distro"

case "$(uname -m)" in
  arm64 | aarch64) deb_arch=arm64 ;;
  *) deb_arch=amd64 ;;
esac

# The distro publishes one package per libc: .deb/.rpm are glibc, .apk is musl. The injector can
# carry both so that a single install serves either kind of image; it selects between them by
# pointing PHP_INI_SCAN_DIR at one directory rather than the other.
libc=glibc
out_dir="${repo_root}/dist/php/${libc}"
install_path="/opt/opentelemetry/php/distro"

rm -rf "$out_dir"
mkdir -p "$out_dir"

asset="opentelemetry-php-distro_${distro_version}_${deb_arch}.deb"
base_url="https://github.com/${distro_repo}/releases/download/v${distro_version}"
echo "==> fetching ${asset} from ${distro_repo}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Plain HTTPS rather than `gh release download`: this runs in CI, where gh would need a token for
# what is an unauthenticated public download.
curl -fsSL -o "${work}/${asset}" "${base_url}/${asset}"
curl -fsSL -o "${work}/${asset}.sha512" "${base_url}/${asset}.sha512"

echo "==> verifying checksum"
(cd "$work" && sha512sum -c "${asset}.sha512" > /dev/null)

echo "==> extracting"
if command -v dpkg-deb > /dev/null 2>&1; then
  dpkg-deb -x "${work}/${asset}" "${work}/root"
else
  # macOS has ar but not dpkg-deb.
  mkdir -p "${work}/root"
  (cd "${work}/root" && ar x "${work}/${asset}" && tar xf data.tar.* && rm -f ./*.tar.* debian-binary)
fi
cp -R "${work}/root${install_path}" "${out_dir}/distro"

# The loader is activated through PHP_INI_SCAN_DIR rather than the distro's post-install script.
# Both lines come from the distro's own manual-setup instructions. Paths are absolute because an
# ini has no notion of its own location, so they must match where the tree is mounted at run time.
cat > "${out_dir}/otel-loader.ini" << EOF
extension=${install_path}/opentelemetry_php_distro_loader.so
opentelemetry_distro.bootstrap_php_part_file=${install_path}/php/bootstrap_php_part.php
EOF

test -f "${out_dir}/distro/opentelemetry_php_distro_loader.so"
test -f "${out_dir}/distro/php/bootstrap_php_part.php"
echo "    -> ${out_dir}"
