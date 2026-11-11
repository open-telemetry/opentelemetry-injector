#!/usr/bin/env bash

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../../.."

# Get the subject line of the most recent commit.
COMMIT_SUBJECT=$(git log -1 --pretty=%s)

# The release PR is created by .github/workflows/scripts/prepare-release.sh. It contains one commit with the message
# "docs: update changelog to prepare release vX.Y.Z", and the PR has the same title. This way, the squash-merged commit
# has this message regardless of whether GitHub uses the commit message (PR with exactly one commit) or the PR title
# (PR with multiple commits). The " (#123)" suffix that GitHub appends is optional.
# The version can have a pre-release suffix like "-rc.1", see tooling/nextversion.
RELEASE_COMMIT_PATTERN='^docs: update changelog to prepare release (v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?)( \(#[0-9]+\))?$'

if [[ "$COMMIT_SUBJECT" =~ $RELEASE_COMMIT_PATTERN ]]; then
  VERSION="${BASH_REMATCH[1]}"
  echo "Found release commit for version: $VERSION."

  # As an additional safeguard against false positives, a release commit must update CHANGELOG.md.
  if ! git diff --name-only HEAD~1 HEAD | grep -qx 'CHANGELOG.md'; then
    echo "The most recent commit looks like a release commit (\"$COMMIT_SUBJECT\"), but it does not modify CHANGELOG.md."
    echo "Not creating a tag. Please check the commit and create the tag manually if necessary."
    exit 1
  fi

  # Create and push tag
  echo "Creating tag for version $VERSION."
  # See https://github.com/open-telemetry/community/blob/9eaa934620638a2f5537d3d74372b389098a8f5e/assets.md#otelbot
  git config user.name otelbot
  git config user.email 197425009+otelbot@users.noreply.github.com
  git tag "$VERSION"
  git push origin "$VERSION"
  echo "Successfully created and pushed tag: $VERSION."
else
  echo "The most recent commit does not seem to be a release commit: \"$COMMIT_SUBJECT\"."
  exit 0
fi
