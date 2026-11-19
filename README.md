## OpenTelemetry Injector

The OpenTelemetry injector is a shared library written in [Zig](https://ziglang.org/) that injects environment variables into processes at startup. It is loaded using [`LD_PRELOAD`](https://man7.org/linux/man-pages/man8/ld.so.8.html#ENVIRONMENT), [`/etc/ld.so.preload`](https://man7.org/linux/man-pages/man8/ld.so.8.html#FILES), or similar mechanisms.

It serves two main purposes:
- Activate OpenTelemetry auto-instrumentation agents to capture and report distributed traces and metrics to the [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/).
- Set resource attributes automatically, such as service and Kubernetes attributes supplied by the deployment environment.

## Installation and Supported Runtimes

This repository publishes only the raw `libotelinject.so` shared library. To enable zero-touch instrumentation, bundle it with the auto-instrumentation agents for your target runtimes and [configure their paths](configuration.md#runtime-specific-requirements-and-behavior).

Official DEB and RPM packages that bundle the injector, auto-instrumentation agents, and configuration are built and published from [open-telemetry/opentelemetry-packaging](https://github.com/open-telemetry/opentelemetry-packaging). Download packages from its [releases page](https://github.com/open-telemetry/opentelemetry-packaging/releases), and report packaging bugs and feature requests in that repository.

The injector supports these runtimes:
- [Java](https://opentelemetry.io/docs/zero-code/java/)
- [Node.js](https://opentelemetry.io/docs/zero-code/js/)
- [.NET](https://opentelemetry.io/docs/zero-code/dotnet/)
- [Ruby](https://github.com/open-telemetry/opentelemetry-ruby-instrumentation)
- Python, which requires a separately provided agent and explicit configuration. See [Python requirements and behavior](configuration.md#python) for the dependency-conflict warning.

## Activation

Install the agents and configure their paths before activating the injector. Package-provided configuration supplies the agent paths for installed runtimes; when providing your own agents, follow the [runtime-specific requirements](configuration.md#runtime-specific-requirements-and-behavior).

To activate the injector for a single process, set `LD_PRELOAD` when starting it:

```bash
LD_PRELOAD=/usr/lib/opentelemetry/libotelinject.so node myapp.js
```

To activate it system-wide for all eligible processes, add the library path to [`/etc/ld.so.preload`](https://man7.org/linux/man-pages/man8/ld.so.8.html#FILES). This requires root privileges:

```bash
echo /usr/lib/opentelemetry/libotelinject.so >> /etc/ld.so.preload
```

These examples use the package installation path. Adjust it if you installed the shared library elsewhere. Restart applications or services after activation or configuration changes.

## Configuration

See the [configuration reference](configuration.md) for all options and detailed behavior:
- [Loading order and precedence](configuration.md#loading-order-and-precedence), including the main file, drop-ins, and environment overrides.
- [File syntax](configuration.md#file-syntax) and [agent environment configuration](configuration.md#agents_env_path).
- [Process selection](configuration.md#process-selection) using executable paths and arguments.
- [Runtime-specific requirements and behavior](configuration.md#runtime-specific-requirements-and-behavior), including agent layouts, environment modifications, and runtime checks.
- [Kubernetes resource mappings](configuration.md#mapping-kubernetes-resource-attributes).
- [Injector logging](configuration.md#log_level).

Disabling [auto-instrumentation](configuration.md#auto_instrumentation_disabled) can still allow resource-attribute injection. Use [complete disablement](configuration.md#disabled) to prevent all injector environment modifications for a workload.

## Verifying Release Artifacts

New raw shared-library assets published by this repository are signed keylessly with [Sigstore Cosign](https://docs.sigstore.dev/cosign/). Each signed `libotelinject_<arch>.so` release asset is accompanied by a `.sigstore.json` bundle containing the material required to verify both the artifact bytes and the GitHub Actions identity that signed them. Releases created before signing was introduced do not contain these bundles.

Install Cosign, choose a release tag and architecture, and download the artifact together with its bundle:

```bash
export REPOSITORY=open-telemetry/opentelemetry-injector
export RELEASE_TAG=v0.0.0 # replace with the release you want to verify
export ARCH=amd64         # or arm64

export ARTIFACT="libotelinject_${ARCH}.so"
export BUNDLE="${ARTIFACT}.sigstore.json"

gh release download "${RELEASE_TAG}" \
  --repo "${REPOSITORY}" \
  --pattern "${ARTIFACT}" \
  --pattern "${BUNDLE}"
```

Verify the artifact against the exact release workflow and tag:

```bash
export CERTIFICATE_IDENTITY="https://github.com/${REPOSITORY}/.github/workflows/build.yml@refs/tags/${RELEASE_TAG}"
export CERTIFICATE_OIDC_ISSUER=https://token.actions.githubusercontent.com

cosign verify-blob "${ARTIFACT}" \
  --bundle "${BUNDLE}" \
  --certificate-identity "${CERTIFICATE_IDENTITY}" \
  --certificate-oidc-issuer "${CERTIFICATE_OIDC_ISSUER}"
```

If verification fails, do not load the artifact. Confirm that the artifact and bundle came from the same release and that `RELEASE_TAG` exactly matches that release tag.

## Limitations

Safe activation is a contract between the injector and the instrumentation library being injected. The library documents the prerequisites for activating it safely and states which of them it verifies itself. The injector verifies the prerequisites assigned to it and does not activate a library whose prerequisites it cannot confirm. This division is being specified in the OpenTelemetry library guidelines, see [open-telemetry/opentelemetry-specification#5267](https://github.com/open-telemetry/opentelemetry-specification/issues/5267).

Most compatibility checking belongs to the instrumentation library. If an application is incompatible with the library being injected, the injector makes no guarantee that the application will work afterwards. The injector performs best-effort runtime version checks for .NET and Java. See the [runtime-specific requirements and limitations](configuration.md#runtime-specific-requirements-and-behavior) before activating instrumentation.

When a runtime check prevents injection, the injector logs why at the `info` level. It only logs errors by default. See [logging configuration](configuration.md#log_level) to diagnose an uninstrumented workload from the application's output.

## Design

This is a short summary of how the injector works internally:
1. Find out which libc the process binds, if any. This is usually either glibc or musl.
   (Some OpenTelemetry SDKs need to be injected differently, e.g. using different binaries depending on the libc
   flavor.)
2. If the process does not bind a libc, or it cannot be identified, the injector aborts injection and hands back control
   to the host process.
3. Find the location of the `dlsym` function in the loaded libc (in memory), reading ELF metadata.
4. Use the libc's `dlsym` handle to look up more symbols in memory, in particular `getenv` and `setenv`.
5. Again, if looking up any of the symbols fails, the injector aborts injection and hands back control to the host
   process.
6. Use the `getenv` function to read the current environment of the process (before adding or modifying any environment
   variables).
7. Use the `setenv` function to add or modify environment variables to add and activate OpenTelemetry
   SDKs/auto-instrumentation agents for supported runtimes (e.g. `NODE_OPTIONS`, `JAVA_TOOL_OPTIONS`,
   `CORECLR_PROFILER`).
8. Use the pointer to the `setenv` symbol to add or modify `OTEL_RESOURCE_ATTRIBUTES`.

There is a much more detailed explanation of this approach, and on alternative approaches and the intricate design
constraints in [DESIGN.md](DESIGN.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

### Maintainers

- [Antoine Toulme](https://github.com/atoulme), [Splunk](https://www.splunk.com/)
- [Bastian Krol](https://github.com/basti1302), [Dash0](https://www.dash0.com/)
- [Jack Berg](https://github.com/jack-berg), [Grafana Labs](https://grafana.com/)
- [Jacob Aronoff](https://github.com/jaronoff97), [Cribl](https://www.cribl.io/)
- [Michele Mancioppi](https://github.com/mmanciop), [Dash0](https://www.dash0.com/)
- [Nikola Grcevski](https://github.com/grcevski), [Grafana Labs](https://grafana.com/)

For more information about the maintainer role, see the [community repository](https://github.com/open-telemetry/community/blob/main/guides/contributor/membership.md#maintainer).

### Project History

The code project was initially donated by [Splunk](https://www.splunk.com/) and later replaced with another code donation
by [Dash0](https://www.dash0.com/).
