#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# Settles the PHP_INI_SCAN_DIR question the injector's composition depends on:
# setting the variable REPLACES the compiled-in scan directory, so a naive
# assignment drops the distro's conf.d. The documented
# escape is that an EMPTY entry in the colon-separated list stands for the
# compiled-in default -- but that needs verifying per version before the
# injector relies on it, because losing conf.d would break applications.
#
# Prints a table of what each candidate value actually scans.

set -uo pipefail

if [[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]]; then arch=arm64; else arch=amd64; fi

# Deliberately repo-local and not mktemp: on macOS the system temp directory is
# outside the paths the Docker VM shares, and a bind mount of a path the VM
# cannot see silently materialises as an empty directory rather than failing.
work="$(cd .. && pwd)/dist/.ini-probe"
rm -rf "$work"
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

# Stands in for a distro-provided conf.d entry that must survive injection.
mkdir -p "$work/distro"
echo 'default_mimetype="DISTRO"' > "$work/distro/zz-distro.ini"

# Stands in for our own loader ini.
mkdir -p "$work/otel"
echo 'user_agent="OTEL"' > "$work/otel/otel-loader.ini"

# shellcheck disable=SC2016  # $d/$o are PHP variables; they must reach PHP unexpanded
probe='$d = ini_get("default_mimetype") === "DISTRO" ? "distro" : "-";
$o = ini_get("user_agent") === "OTEL" ? "otel" : "-";
echo $d . "," . $o;'

printf '%-6s  %-26s  %s\n' "php" "PHP_INI_SCAN_DIR" "scanned"
printf '%-6s  %-26s  %s\n' "-----" "--------------------------" "-------------"

for v in 8.1 8.2 8.3 8.4 8.5; do
  image="php:${v}-cli"
  docker image inspect "$image" > /dev/null 2>&1 || docker pull --platform "linux/${arch}" "$image" > /dev/null 2>&1 || continue

  for value in "<unset>" "/otel" ":/otel" "/otel:" "/distro:/otel"; do
    if [[ "$value" == "<unset>" ]]; then
      env_args=()
    else
      mapped="${value//\/otel//opt/otel}"
      mapped="${mapped//\/distro//opt/distro}"
      env_args=(-e "PHP_INI_SCAN_DIR=${mapped}")
    fi

    result="$(docker run --rm --platform "linux/${arch}" \
      -v "$work/distro/zz-distro.ini:/usr/local/etc/php/conf.d/zz-distro.ini:ro" \
      -v "$work/distro:/opt/distro:ro" \
      -v "$work/otel:/opt/otel:ro" \
      "${env_args[@]+"${env_args[@]}"}" \
      "$image" php -r "$probe" 2>/dev/null)"

    printf '%-6s  %-26s  %s\n' "$v" "$value" "$result"
  done
done
