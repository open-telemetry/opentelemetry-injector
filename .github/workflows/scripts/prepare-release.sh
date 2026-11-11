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
# The commit message and the PR title must both be exactly "docs: update changelog to prepare release ${VERSION}".
# When the PR is squash-merged, GitHub uses the commit message if the PR has exactly one commit, and the PR title
# otherwise (e.g. when someone has pushed additional changelog edits to the release branch). The resulting commit on
# main is detected by .github/workflows/scripts/create-tag-for-release.sh, which creates the release tag only if the
# commit message matches the pattern RELEASE_COMMIT_PATTERN defined there. If you change the commit message or the PR
# title here, update that pattern accordingly, otherwise no release tag will be created.
git commit -m "docs: update changelog to prepare release ${VERSION}"

git push --set-upstream origin "${BRANCH}"

# The PR title must match the commit message above, see the comment there.
gh pr create --head "$(git branch --show-current)" --title "docs: update changelog to prepare release ${VERSION}" --body "
The following commands were run to prepare this release:
- make chlog-update VERSION=${VERSION}
"

