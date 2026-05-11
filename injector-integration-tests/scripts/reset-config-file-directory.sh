#!/usr/bin/env sh

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# Resets the test container's mutable file system state to a clean baseline so each test case starts isolated from modifications
# made by previous test cases. Invoked from the function run_test_case in run-tests-within-container.sh, before every test case.
# Run with the workdir set to /usr/src/otel/injector/ (the same home directory used by run_test_case), so common/conf.d/ resolves
# to the source files.

set -e

# Delete the entire configuration directory to remove all potentially modified config files.
rm -rf /etc/opentelemetry/injector

# Clean up the optional .NET directories that create-sdk-dummy-files-dotnet-optional.sh creates for test cases
# labelled "...the additional deps directory exists..." or "...the shared store directory exists...". Skip when the
# parent tree is intentionally inaccessible (sdk-cannot-be-accessed.tests chmod-s it to 600).
if [ -d /usr/lib/opentelemetry ] && [ -x /usr/lib/opentelemetry ]; then
  rm -rf /usr/lib/opentelemetry/dotnet/glibc/AdditionalDeps
  rm -rf /usr/lib/opentelemetry/dotnet/musl/AdditionalDeps
  rm -rf /usr/lib/opentelemetry/dotnet/glibc/store
  rm -rf /usr/lib/opentelemetry/dotnet/musl/store
fi

# Restore the original configuration file layout.
scripts/create-config-file-directory.sh
