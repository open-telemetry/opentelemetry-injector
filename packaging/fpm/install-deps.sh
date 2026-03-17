#!/bin/bash

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

set -euxo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

apt-get update

apt-get install -y ruby ruby-dev rubygems build-essential git rpm curl jq ruby-bundler unzip

bundle install --gemfile "${SCRIPT_DIR}/Gemfile"
