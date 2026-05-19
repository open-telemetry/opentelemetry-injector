#!/usr/bin/env sh

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# (Re-)build the default configuration directory layout that the OpenTelemetry injector integration test framework expect inside
# the test container. Invoked from each test app Dockerfile at image build time, and also at the start of each test case.
#
# The conf.d drop-in files are staged under common/conf.d/ (the Dockerfile is responsible for the COPY); this script
# populates the runtime location /etc/opentelemetry/injector/conf.d/ from that stage and gives the test user write
# access. The same staging directory is used by reset-config-file-directory.sh to restore conf.d between test cases.

set -e

mkdir -p /etc/opentelemetry/injector/conf.d

cp common/injector.conf /etc/opentelemetry/injector/injector.conf
if [ -d common/conf.d ]; then
  find common/conf.d -maxdepth 1 -name '*.conf' -exec cp {} /etc/opentelemetry/injector/conf.d/ \;
fi
