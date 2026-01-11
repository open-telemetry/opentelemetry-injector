# Releasing the injector

An approver or maintainer can run the GitHub action to [prepare the release from the GitHub Actions page of the repository](https://github.com/open-telemetry/opentelemetry-injector/actions/workflows/prepare-release.yml).

The pattern for the version should be vX.Y.Z for a regular release, or vX.Y.Z-<additional-qualfier> for a release candidate.

The action will trigger the creation of a pull request for review by project approvers ([example](https://github.com/open-telemetry/opentelemetry-injector/pull/112)).

Approvers approve the changelog and merge the PR.

Merging the PR will trigger the workflow `.github/workflows/create-tag-for-release.yml` which will create a tag with the
version number.

Creating the tag will trigger the `build` GitHub action workflow, which will then create the GitHub release in the last
job (`publish-stable`).
(This can take a couple of minutes.)

## Announce the release

Make sure to drop the good news of the release to the CNCF slack #otel-injector channel!

