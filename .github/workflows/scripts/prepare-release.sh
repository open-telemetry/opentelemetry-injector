#!/bin/bash -ex

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# Usage: VERSION=v1.2.3 ./prepare-release.sh
# Calls make chlog-update to compile all changelog entries from .chloggen and add them to the main CHANGELOG.md file,
# then creates a PR with this change.

PATTERN="^v[0-9]+\.[0-9]+\.[0-9]+.*"

if [[ "$VERSION" == [0-9]* ]]; then
  # normalize the VERSION input without leading "v"
  VERSION="v$VERSION"
fi

if ! [[ ${VERSION} =~ $PATTERN ]]
then
  echo "VERSION should follow the semver format (with a leading v), i.e. v1.2.3 or v1.2.3-qualifier."
  exit 1
fi

git config user.name opentelemetrybot
git config user.email 107717825+opentelemetrybot@users.noreply.github.com

BRANCH="prepare-release-prs/${VERSION}"
git checkout -b "${BRANCH}"

make chlog-update VERSION="${VERSION}"
git add --all
git commit -m "docs: update changelog to prepare release ${VERSION}"

git push --set-upstream origin "${BRANCH}"

gh pr create --head "$(git branch --show-current)" --title "chore: prepare release ${VERSION}" --body "
The following commands were run to prepare this release:
- make chlog-update VERSION=v${VERSION}
"

