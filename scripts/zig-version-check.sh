#!/usr/bin/env bash

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# Verifies that the two Zig version references in this repository agree with each other, and prints the version they
# agree on to stdout.
#
# The two references drive different Zig toolchains, which is why a mismatch does not necessarily show up as a build
# failure:
#   * ZIG_VERSION in ./zig-version is the Zig version that Dockerfile and devel.Dockerfile download, and the version
#     that CONTRIBUTING.md asks contributors to install locally.
#   * .minimum_zig_version in ./build.zig.zon is the lower bound that "zig build" enforces, and it is also the version
#     that mlugg/setup-zig installs in CI: .github/workflows/build.yml pins no version, and with an empty version
#     input that action resolves the version from the minimum_zig_version field in build.zig.zon.
# If the two drift apart, CI silently verifies and tests the injector with a different Zig version than the one the
# container builds ("make dist") and contributors use.
#
# Both files carry a comment asking for them to be kept in sync. This script is what actually enforces it. It is
# invoked from the make target zig-version-check (part of "make lint") and from
# .github/workflows/scripts/update-zig.sh, which uses it to read the current Zig version.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

zig_version_file=zig-version
build_zig_zon_file=build.zig.zon

# Matches a stable Zig version like "0.16.0".
zig_version_regex='[0-9]+\.[0-9]+\.[0-9]+'

# Note: the "|| true" in the two lookups below keeps grep finding no match from aborting the script via "set -e", so
# that the checks for an empty result can report what exactly could not be determined.
zig_version=$(grep -oE "^ZIG_VERSION=${zig_version_regex}$" "$zig_version_file" | head -n 1 | cut -d= -f2 || true)
if [[ -z "$zig_version" ]]; then
  echo "Error: cannot determine the Zig version from ZIG_VERSION in ./${zig_version_file}." >&2
  exit 1
fi

minimum_zig_version=$(
  grep -oE "\.minimum_zig_version = \"${zig_version_regex}\"" "$build_zig_zon_file" |
    head -n 1 |
    grep -oE "$zig_version_regex" ||
    true
)
if [[ -z "$minimum_zig_version" ]]; then
  echo "Error: cannot determine the Zig version from .minimum_zig_version in ./${build_zig_zon_file}." >&2
  exit 1
fi

if [[ "$zig_version" != "$minimum_zig_version" ]]; then
  echo "Error: the Zig version references in this repository are out of sync: ZIG_VERSION in ./${zig_version_file} is ${zig_version}, but .minimum_zig_version in ./${build_zig_zon_file} is ${minimum_zig_version}. Please set both to the same version." >&2
  exit 1
fi

echo "$zig_version"
