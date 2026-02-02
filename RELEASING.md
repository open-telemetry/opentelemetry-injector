# Releasing the injector

An approver or maintainer runs the GitHub action to [prepare the release from the GitHub Actions page of the repository](https://github.com/open-telemetry/opentelemetry-injector/actions/workflows/prepare-release.yml).

The pattern for the version should be vX.Y.Z for a regular release, or vX.Y.Z-<additional-qualifier> for a release candidate.

The action will trigger the creation of a pull request for review by project approvers ([example](https://github.com/open-telemetry/opentelemetry-injector/pull/112)).

Approvers approve the changelog and merge the PR.

Merging the PR will trigger the workflow `.github/workflows/create-tag-for-release.yml` which will create a tag with the
version number.

Creating the tag will trigger the `build` GitHub action workflow, which will then create the GitHub release in the last
job (`publish-stable`).
(This can take a couple of minutes.)

## Announce the release

Make sure to drop the good news of the release to the CNCF slack #otel-injector channel!

## Update the release schedule

Update the table below to move yourself to the bottom of the table.

# Release schedule

Approvers of the opentelemetry-injector repository perform releases per schedule.

| Date       | Version | Release manager  |
|------------|---------|------------------|
| 2026-01-10 | 0.0.3   | [@basti1302][1]  |
| 2026-02-02 | 0.0.4   | [@atoulme][0]    |
| 2026-02-16 | 0.0.5   | [@jack-berg][2]  |
| 2026-03-02 | 0.0.5   | [@jaronoff97][3] |
| 2026-03-16 | 0.0.6   | [@mmanciop][4]   |
| 2026-03-30 | 0.0.7   | [@grcevski][5]   |
| 2026-04-13 | 0.0.8   | [@basti1302][1]  |
| 2026-04-27 | 0.0.9   | [@atoulme][0]    |

[0]: https://github.com/atoulme
[1]: https://github.com/basti1302
[2]: https://github.com/jack-berg
[3]: https://github.com/jaronoff97
[4]: https://github.com/mmanciop
[5]: https://github.com/grcevski
