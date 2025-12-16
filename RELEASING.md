# Releasing the injector

## Prepare the release

An approver or maintainer can run the GitHub action to [prepare the release from the GitHub Actions page of the repository](https://github.com/open-telemetry/opentelemetry-injector/actions/workflows/prepare-release.yml).

Enter a valid version string in the dialog (here _without_ the `v` prefix).
The pattern for the version should be X.Y.Z for a regular release, or X.Y.Z-<additional-qualfier> for a release candidate.

The action will trigger the creation of a pull request for review by project approvers ([example](https://github.com/open-telemetry/opentelemetry-injector/pull/112)).

Approvers approve the changelog and merge the PR.

## Cut the release

_TODO_: this can be automated. See https://github.com/open-telemetry/opentelemetry-injector/issues/115

To cut the release, approvers create a tag matching the commit of the PR that was just merged, with an additional `v` prefix.

They can do so either through GitHub or by pushing it via `git tag vX.Y.Z && git push origin --tags`.

They create a release on this tag and copy the section of the CHANGELOG.md for the release, adding more information as needed ([example](https://github.com/open-telemetry/opentelemetry-injector/releases/tag/v0.0.1-20251030)).

If the release is not meant for production use, check the box to mark the release as pre-release.

Publish the release with the "Publish release" button.

## Add convenience binaries

_TODO_: this can be automated. See https://github.com/open-telemetry/opentelemetry-injector/issues/115

On your machine, run the following:
* Switch to the tag for the release created in the previous step, i.e. `git fetch origin --tags; git checkout vX.Y.Z`.
* Build assets:
    ```bash
    # clean local artifacts, build the injector binaries and packages for both architectures
    $> make clean && make dist deb-package rpm-package ARCH=arm64 && make dist deb-package rpm-package ARCH=amd64
    ```

Upload the resulting files to the GitHub release assets:
* the `libotelinject_*.so` binaries from `dist` for all supported CPU architectures
* the Debian (`opentelemetry-injector-*.deb`) and RPM (`opentelemetry-injector-*.rpm`) packages for all supported CPU architectures from `instrumentation/dist/`

## Announce the release

Make sure to drop the good news of the release to the CNCF slack #otel-injector channel!

