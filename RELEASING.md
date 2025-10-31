# Releasing the injector

## Prepare the release

An approver or maintainer can run the GitHub action to [prepare the release from the GitHub Actions page of the repository](https://github.com/open-telemetry/opentelemetry-injector/actions/workflows/prepare-release.yml).

Please enter a valid version string in the dialog.

The action will trigger the creation of a pull request for review by project approvers ([example](https://github.com/open-telemetry/opentelemetry-injector/pull/112)).

Approvers approve the changelog and merge the PR.

## Cut the release

_TODO_: this can be automated. See https://github.com/open-telemetry/opentelemetry-injector/issues/115 

To cut the release, approvers create a tag matching the commit of the PR that was just merged.

They can do so either through GitHub or by pushing it via `git tag xxx && git push origin --tags`.

The tag name must match the version they just created in the changelog.

They create a release on this tag and copy the section of the CHANGELOG.md for the release, adding more information as needed ([example](https://github.com/open-telemetry/opentelemetry-injector/releases/tag/v0.0.1-20251030)).

If the release is not meant for production use, please check the box to mark the release as Draft.

## Add convenience binaries

_TODO_: this can be automated. See https://github.com/open-telemetry/opentelemetry-injector/issues/115

On your laptop, run the following:

```bash
$> make clean # clean the local artifacts
$> make deb-package rpm-package # Build the artifacts
```

Upload the `instrumentation/*.so`, `instrumentation/dist/*` files to the GitHub release assets.

## Announce the release

Make sure to drop the good news of the release to the CNCF slack #otel-injector channel!
