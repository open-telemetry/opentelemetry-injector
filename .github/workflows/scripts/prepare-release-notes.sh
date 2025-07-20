#!/bin/bash -ex

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

touch release-notes.md
echo "## Changelog" >> release-notes.md

awk '/<!-- next version -->/,/<!-- previous-version -->/' CHANGELOG.md > tmp-chlog.md # select changelog of latest version only
sed '1,3d' tmp-chlog.md >> release-notes.md # delete first 3 lines of file
