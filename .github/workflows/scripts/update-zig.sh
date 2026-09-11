#!/usr/bin/env bash

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# Checks whether a new stable Zig release is available and, if so, opens a pull request that updates the two Zig
# version references in this repository: ZIG_VERSION in ./zig-version and .minimum_zig_version in ./build.zig.zon.
#
# The pull request deliberately changes nothing else. It does not attempt to migrate the code base to the new Zig
# version, that can hardly be automated. The pull request is only meant as a signal to the maintainers that a new Zig
# release exists, and as a starting point for the migration. Its CI run will usually fail, that is expected.
#
# This is invoked from the update-zig.yaml workflow.
#
# It needs two separate GitHub tokens, because no single otelbot app can do both halves of the job:
#   * GH_TOKEN_CONTENTS creates the branch and the commit on it. The injector-specific otelbot app grants
#     contents: write, the main otelbot app does not.
#   * GH_TOKEN_PULL_REQUESTS creates the pull request and its comment. The main otelbot app grants
#     pull requests: write.
# See the comments in update-zig.yaml for why the two cannot be collapsed into one token.

set -euo pipefail

for executable in curl gh git jq; do
  if ! command -v "$executable" &> /dev/null; then
    echo "Error: the $executable executable is not available." >&2
    exit 1
  fi
done

for variable in GITHUB_REPOSITORY GH_TOKEN_CONTENTS GH_TOKEN_PULL_REQUESTS; do
  if [[ -z "${!variable:-}" ]]; then
    echo "Error: the $variable environment variable is not set." >&2
    exit 1
  fi
done

# Wrappers that make every gh call state which of the two tokens it needs. Using the wrong token here does not fail
# with a helpful message, it fails with a plain 404 or 403 from the GitHub API.
gh_contents() {
  GH_TOKEN="$GH_TOKEN_CONTENTS" gh "$@"
}

gh_pull_requests() {
  GH_TOKEN="$GH_TOKEN_PULL_REQUESTS" gh "$@"
}

cd "$(dirname "${BASH_SOURCE[0]}")/../../.."

# Reads the Zig version that the repository currently uses. This also verifies that the two version references are in
# sync and fails if they are not: updating both of them to a new version would silently paper over the discrepancy, so
# it has to be resolved manually first. The same check runs as part of "make lint".
current_version=$(scripts/zig-version-check.sh)

# The download index on ziglang.org is the authoritative source for Zig releases, see
# https://ziglang.org/download/. The GitHub repository ziglang/zig is only a mirror of
# https://codeberg.org/ziglang/zig and is not a usable source: it has neither a tag nor a GitHub release for 0.16.0,
# and "gh api repos/ziglang/zig/releases/latest" still reports 0.15.1.
index_json=$(curl -sS --fail --retry 3 https://ziglang.org/download/index.json)

# Matches a stable Zig version like "0.16.0". Development builds ("0.17.0-dev.2085+5e36170b5") and release candidates
# deliberately do not match.
zig_version_regex='[0-9]+\.[0-9]+\.[0-9]+'

# The index has one entry per stable release, plus a "master" entry for the current development build. Every entry is
# reduced to its version and only stable versions are kept, which excludes "master" and any release candidate.
latest_version=$(
  jq -r 'to_entries[] | .value.version // .key' <<< "$index_json" |
    grep -E "^${zig_version_regex}$" |
    sort -V |
    tail -n 1 ||
    true
)
if [[ -z "$latest_version" ]]; then
  echo "Error: cannot determine the latest stable Zig release from https://ziglang.org/download/index.json." >&2
  exit 1
fi

echo "current Zig version:       $current_version"
echo "latest stable Zig release: $latest_version"

newer_version=$(printf '%s\n%s\n' "$current_version" "$latest_version" | sort -V | tail -n 1)
if [[ "$latest_version" == "$current_version" || "$newer_version" != "$latest_version" ]]; then
  echo "No update necessary, the Zig version is up to date."
  exit 0
fi

branch_name="update-zig-${latest_version}"

# An open pull request for this Zig version means that the maintainers have already been notified about this release
# and there is nothing left to do, so stop here without failing the run.
existing_pr=$(gh_pull_requests pr list --repo "$GITHUB_REPOSITORY" --head "$branch_name" --state open --json url --jq '.[0].url // empty')
if [[ -n "$existing_pr" ]]; then
  echo "The pull request ${existing_pr} updates Zig to ${latest_version} already. Stopping here."
  exit 0
fi

echo "Updating the Zig version from ${current_version} to ${latest_version}."

zig_version_file=zig-version
build_zig_zon_file=build.zig.zon
sed -i.bak -E "s/^ZIG_VERSION=${zig_version_regex}$/ZIG_VERSION=${latest_version}/" "$zig_version_file"
rm -f "${zig_version_file}.bak"
sed -i.bak -E "s/(\.minimum_zig_version = \")${zig_version_regex}(\")/\1${latest_version}\2/" "$build_zig_zon_file"
rm -f "${build_zig_zon_file}.bak"

mapfile -t changed_files < <(git diff --name-only -- "$zig_version_file" "$build_zig_zon_file")
if [[ ${#changed_files[@]} -ne 2 ]]; then
  echo "Error: expected ./${zig_version_file} and ./${build_zig_zon_file} to be updated to ${latest_version}, but ${#changed_files[@]} file(s) have been changed: ${changed_files[*]}" >&2
  exit 1
fi

echo
echo git diff:
git --no-pager diff -- "${changed_files[@]}"
echo

# Base commit that the new branch will be based on.
base_sha=$(git rev-parse HEAD)

# There is no open pull request for this version (verified above), but the branch can still exist: an earlier run may
# have failed between creating the branch and creating the pull request, or a pull request for this version has been
# closed without merging it. Creating a ref that already exists fails, so delete it and start over from the current
# base commit.
if gh_contents api "repos/${GITHUB_REPOSITORY}/git/ref/heads/${branch_name}" > /dev/null 2>&1; then
  echo "Deleting the leftover branch \"${branch_name}\", which has no open pull request."
  gh_contents api --method DELETE "repos/${GITHUB_REPOSITORY}/git/refs/heads/${branch_name}" > /dev/null
fi

# Everything from here on can fail halfway through, leaving a branch without a pull request behind. Delete the branch
# again in that case, so the next run starts from a clean slate and actually retries the notification.
branch_created=false
cleanup_branch() {
  if [[ "$branch_created" == true ]]; then
    echo "The run failed before the pull request has been created, deleting the branch \"${branch_name}\" again." >&2
    gh_contents api --method DELETE "repos/${GITHUB_REPOSITORY}/git/refs/heads/${branch_name}" > /dev/null || true
  fi
}
trap cleanup_branch EXIT

# createCommitOnBranch can only commit onto a branch that already exists. Create the pull request branch at the base
# commit; we have made sure above that the branch does not exist yet.
gh_contents api --method POST "repos/${GITHUB_REPOSITORY}/git/refs" \
  -f ref="refs/heads/${branch_name}" \
  -f sha="${base_sha}" > /dev/null
branch_created=true

commit_message="chore(deps): update Zig to ${latest_version}"
commit_body=$(
  cat << EOF
Updates the two Zig version references to ${latest_version}.
EOF
)

# Let "gh api graphql"/createCommitOnBranch create the commit via the GitHub API rather than "git commit"/"git push",
# so the commit is automatically signed.
# Note: expectedHeadOid is an optimistic lock: the branch tip must still be at base_sha (it is, we just created it).
additions=$(
  for file in "${changed_files[@]}"; do
    # Reading from stdin and stripping the line breaks afterwards keeps this working with both GNU base64 (which wraps
    # at 76 characters unless -w0 is given) and BSD base64 (which has no -w and needs -i for a file argument).
    jq -n --arg path "$file" --arg contents "$(base64 < "$file" | tr -d '\n')" '{path: $path, contents: $contents}'
  done | jq -s '.'
)

jq -n \
  --arg repo "$GITHUB_REPOSITORY" \
  --arg branch "$branch_name" \
  --arg headline "$commit_message" \
  --arg body "$commit_body" \
  --arg oid "$base_sha" \
  --argjson additions "$additions" \
  '{
    query: "mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }",
    variables: {
      input: {
        branch:          { repositoryNameWithOwner: $repo, branchName: $branch },
        message:         { headline: $headline, body: $body },
        expectedHeadOid: $oid,
        fileChanges:     { additions: $additions }
      }
    }
  }' | gh_contents api graphql --input - > /dev/null

pr_body="Upgrade from Zig ${current_version} to ${latest_version}."
pr_url=$(
  gh_pull_requests pr create \
    -B main \
    -H "$branch_name" \
    --title "$commit_message" \
    --body "$pr_body"
)

# The pull request exists now, the branch must not be deleted anymore in the trap, no matter what happens below.
branch_created=false
echo "Created pull request ${pr_url}."


# Release notes are published for minor releases but not for every patch release, so only link them if they exist.
release_notes_url="https://ziglang.org/download/${latest_version}/release-notes.html"
if [[ "$(curl -sS --retry 3 -o /dev/null -w '%{http_code}' "$release_notes_url")" == 200 ]]; then
  release_notes_link="[release notes for Zig ${latest_version}](${release_notes_url})"
else
  release_notes_link="[download page](https://ziglang.org/download/)"
fi

pr_comment=$(
  cat << EOF
Zig ${latest_version} has been released. This pull request updates the two Zig version references in this repository:
* \`ZIG_VERSION\` in \`zig-version\`
* \`.minimum_zig_version\` in \`build.zig.zon\`

The automatically created commit does **not** migrate the code base to Zig ${latest_version}.
The automatic creation of this pull request is mainly meant as a signal that a new Zig release is available.
**Its initial CI run will most likely fail, which is expected**.

Use it as a starting point for the migration. See the ${release_notes_link} for what has changed.

This pull request has been created by the \`.github/workflows/update-zig.yaml\` workflow.
EOF
)
gh_pull_requests pr comment "$pr_url" --body "$pr_comment" > /dev/null
echo "Added the comment explaining that this pull request is not a migration to Zig ${latest_version}."
