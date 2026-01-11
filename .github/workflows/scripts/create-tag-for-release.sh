#!/usr/bin/env bash

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../../.."

# Get the most recent commit message
COMMIT_MSG=$(git log -1 --pretty=%B)

# Check if commit message matches release pattern and extract version
if [[ "$COMMIT_MSG" =~ ^docs:\ update\ changelog\ to\ prepare\ release\ (v[0-9]+\.[0-9]+\.[0-9]+.*)$ ]]; then
  VERSION="${BASH_REMATCH[1]}"
  echo "Found release commit for version: $VERSION."

  # Create and push tag
  echo "Creating tag for version $VERSION."
  git config user.name opentelemetrybot
  git config user.email 107717825+opentelemetrybot@users.noreply.github.com
  git tag "$VERSION"
  git push origin "$VERSION"
  echo "Successfully created and pushed tag: $VERSION."
else
  echo "The most recent commit does not seem to be a release commit."
  exit 0
fi
