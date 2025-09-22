#!/usr/bin/env bash

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# Adapted from https://stackoverflow.com/a/74241578/2565264.

set -euo pipefail

# This is for Tomcat 10. Use https://tomcat.apache.org/download-11.cgi for Tomcat 11 etc.
download_page=https://tomcat.apache.org/download-10.cgi

tomcat_download_url=$(curl -sS "$download_page" | grep \
 '>tar.gz</a>' | head -1 | grep -E -o 'https://[a-z0-9:./-]+.tar.gz')
echo $tomcat_download_url
