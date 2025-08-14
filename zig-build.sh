#!/usr/bin/env bash

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# A small helper script intended to be used with entr, like so:
# fd | entr ./zig-build.sh
# ...to get fast feedback on compile errors when working on the Zig code.
# See also: ./watch-zig-build.sh
# The point is that `zig build` does not print anything when there have been no changes since the last successful build,
# which makes it hard to tell (when using entr) whether the build is still ongoing or there simply was nothing to do.
# This script will simply print a message indicating the successful build to circumvent this.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if zig build --prominent-compile-errors --summary none; then
  echo "$(date) build successful"
  echo
else
  echo "$(date) build failed"
  echo
fi
