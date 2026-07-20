# Releasing the injector

An approver or maintainer can run the GitHub action to [prepare the release from the GitHub Actions page of the repository](https://github.com/open-telemetry/opentelemetry-injector/actions/workflows/prepare-release.yml).

The action asks for an `override` input with the choices `auto` (default), `major`, `minor`, or `patch`. When left as `auto`, the release-tooling program at [tooling/nextversion](tooling/nextversion) derives the bump from the `change_type` of the chloggen entries in [.chloggen](.chloggen) (`breaking` -> major, `deprecation`/`new_component`/`enhancement` -> minor, `bug_fix` -> patch; while the current release is on `0.y.z`, a `breaking` change is bumped as minor per the semver 0.x convention). Any of `major`, `minor`, `patch` overrides the auto-derived bump. The action then bumps the appropriate component of the most recent stable `vX.Y.Z` tag, so there is no need to type out the full version.

The action will trigger the creation of a pull request for review by project approvers ([example](https://github.com/open-telemetry/opentelemetry-injector/pull/112)).

Approvers approve the changelog and merge the PR.
(The person approving and merging the changelog PR can be the same person who triggered the `prepare-release` action.)

Merging the PR will trigger the workflow `.github/workflows/create-tag-for-release.yml` which will create a tag with the
version number.

Creating the tag will trigger the `build` GitHub action workflow, which will then create the GitHub release in the last
job (`publish-stable`).
(This can take a couple of minutes.)

## Announce the release

Make sure to drop the good news of the release to the CNCF slack #otel-injector channel!

