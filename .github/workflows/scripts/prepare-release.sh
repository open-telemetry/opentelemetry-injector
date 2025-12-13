#!/bin/bash -ex

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

PATTERN="^[0-9]+\.[0-9]+\.[0-9]+.*"

if ! [[ ${CANDIDATE} =~ $PATTERN ]]
then
    echo "CANDIDATE should follow a semver format and not be led by a v"
    exit 1
fi

git config user.name opentelemetrybot
git config user.email 107717825+opentelemetrybot@users.noreply.github.com

BRANCH="prepare-release-prs/${CANDIDATE}"
git checkout -b "${BRANCH}"

make chlog-update VERSION="v${CANDIDATE}"
git add --all
git commit -m "changelog update ${CANDIDATE}"

git push --set-upstream origin "${BRANCH}"

gh pr create --head "$(git branch --show-current)" --title "chore: prepare release ${CANDIDATE}" --body "
The following commands were run to prepare this release:
- make chlog-update VERSION=v${CANDIDATE}
"
