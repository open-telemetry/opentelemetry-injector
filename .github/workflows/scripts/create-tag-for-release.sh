#!/usr/bin/env bash

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../../.."

# Get the most recent commit message
COMMIT_MSG=$(git log -1 --pretty=%B)

# Check if commit message matches release pattern and extract version
if [[ "$COMMIT_MSG" =~ ^docs:\ update\ changelog\ to\ prepare\ release\ (v[0-9]+\.[0-9]+\.[0-9]+(-[[:alnum:]]+)?).*$ ]]; then
  VERSION="${BASH_REMATCH[1]}"
  echo "Found release commit for version: $VERSION."

  # Create and push tag
  echo "Creating tag for version $VERSION."
  # See https://github.com/open-telemetry/community/blob/9eaa934620638a2f5537d3d74372b389098a8f5e/assets.md#otelbot
  git config user.name otelbot
  git config user.email 197425009+otelbot@users.noreply.github.com
  git tag "$VERSION"
  git push origin "$VERSION"
  echo "Successfully created and pushed tag: $VERSION."
else
  echo "The most recent commit does not seem to be a release commit."
  exit 0
fi
