## OpenTelemetry Injector

The OpenTelemetry injector is a shared library (written in [Zig](https://ziglang.org/)) that is intended to be
used via the environment variable [`LD_PRELOAD`](https://man7.org/linux/man-pages/man8/ld.so.8.html#ENVIRONMENT), the
[`/etc/ld.so.preload`](https://man7.org/linux/man-pages/man8/ld.so.8.html#FILES) file, or similar mechanisms to inject
environment variables into processes at startup.

It serves two main purposes:
* Inject an OpenTelemetry Auto Instrumentation agent into the process to capture and report distributed traces and
  metrics to the [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/) for supported runtimes.
* Set resource attributes automatically, (for example Kubernetes related resource attributes and service related
  resource attributes in environments where this is applicable).

The injector can be used to enable automatic zero-touch instrumentation of processes.
For this to work, the injector binary needs to be bundled together with the OpenTelemetry auto-instrumentation agents
for the target runtimes.

Official RPM and DEB packages that contain the injector as well as the auto-instrumentation agents are available, and
can be downloaded from the [releases page](https://github.com/open-telemetry/opentelemetry-injector/releases).
The OpenTelemetry injector Debian/RPM packages install the OpenTelemetry auto-instrumentation agents, the
`libotelinject.so` shared object library, and a default configuration file to automatically instrument applications and
services to capture and report distributed traces and metrics to the
[OpenTelemetry Collector](https://opentelemetry.io/docs/collector/)

The `opentelemetry-injector` deb/rpm package installs and supports configuration of the following Auto
Instrumentation agents:

- [Java](https://opentelemetry.io/docs/zero-code/java/)
- [Node.js](https://opentelemetry.io/docs/zero-code/js/)
- [.NET](https://opentelemetry.io/docs/zero-code/dotnet/)

## Activation and Configuration

The following methods are supported to manually activate and configure Auto Instrumentation after installation of the
`opentelemetry-injector` deb/rpm package (requires `root` privileges):

- [System-wide](#system-wide-or-per-process)
- [`Systemd` services only](#systemd-services-only)

> **Note**: To prevent conflicts and duplicate traces/metrics, only one method should be activated on the target system.

### System-wide or per process

1. Add the path of the provided `/usr/lib/opentelemetry/libotelinject.so` shared object library to the
   [`/etc/ld.so.preload`](https://man7.org/linux/man-pages/man8/ld.so.8.html#FILES) file to activate Auto
   Instrumentation for ***all*** supported processes on the system. For example:
   ```
   echo /usr/lib/opentelemetry/libotelinject.so >> /etc/ld.so.preload
   ```
   Alternatively, set the environment variable `LD_PRELOAD=/usr/lib/opentelemetry/libotelinject.so` for a specific
   process to activate auto-instrumentation for tha process. For example:
   ```
   LD_PRELOAD=/usr/lib/opentelemetry/libotelinject.so node myapp.js
   ```
2. The default configuration file `/etc/opentelemetry/otelinject.conf` includes the required settings, i.e. the paths to
   the respective auto-instrumentation agents per runtime:
   ```
   dotnet_auto_instrumentation_agent_path_prefix=/usr/lib/opentelemetry/dotnet
   jvm_auto_instrumentation_agent_path=/usr/lib/opentelemetry/javaagent.jar
   nodejs_auto_instrumentation_agent_path=/usr/lib/opentelemetry/otel-js/node_modules/@opentelemetry-js/otel/instrument
   ```
   There is usually no need to modify this file, unless you want to provide your own instrumentation files.

   However, the configuration file `/etc/opentelemetry/otelinject.conf` can also be used to selectively disable
   auto-instrumentation for a specific runtime, by setting the respective path to an empty string.
   For example, the following file would leave JVM and Node.js auto-instrumentation active, while disabling .NET
   auto-instrumentation:
   ```
   dotnet_auto_instrumentation_agent_path_prefix=
   jvm_auto_instrumentation_agent_path=/usr/lib/opentelemetry/javaagent.jar
   nodejs_auto_instrumentation_agent_path=/usr/lib/opentelemetry/otel-js/node_modules/@opentelemetry-js/otel/instrument
   ```

   The paths set in `/etc/opentelemetry/otelinject.conf` can be overridden with environment variables.
   (This should usually not be necessary.)
   - `DOTNET_AUTO_INSTRUMENTATION_AGENT_PATH_PREFIX`: the path to the directory containing the .NET Auto Instrumentation
     agent files
   - `JVM_AUTO_INSTRUMENTATION_AGENT_PATH`: the path to the Java auto-instrumentation agent JAR file
   - `NODEJS_AUTO_INSTRUMENTATION_AGENT_PATH`: the path to the Node.js auto-instrumentation agent registration file

   These aforementioned environment variables can also be used to selectively disable auto-instrumentation for a
   specific runtime, by setting the respective variable to an empty string, that is, set:
    - `DOTNET_AUTO_INSTRUMENTATION_AGENT_PATH_PREFIX=""` to disable .NET auto-instrumentation
    - `JVM_AUTO_INSTRUMENTATION_AGENT_PATH=""` to disable JVM auto-instrumentation
    - `NODEJS_AUTO_INSTRUMENTATION_AGENT_PATH=""` to disable Node.js auto-instrumentation
3. Reboot the system or restart the applications/services for any changes to take effect. The `libotelinject.so` shared
   object library will then be preloaded for all subsequent processes and inject the environment variables from the
   `/etc/opentelemetry/otelinject` configuration files for Java and Node.js processes.

When providing your own instrumentation files (for example via environment variables like `DOTNET_AUTO_INSTRUMENTATION_AGENT_PATH_PREFIX`) the following directory structure is expected:
- `JVM_AUTO_INSTRUMENTATION_AGENT_PATH`: This path must point to the Java auto-instrumentation agent JAR file `opentelemetry-javaagent.jar`.
- `NODEJS_AUTO_INSTRUMENTATION_AGENT_PATH`: The path to an installation of the npm module `@opentelemetry/auto-instrumentations-node`.
- `DOTNET_AUTO_INSTRUMENTATION_AGENT_PATH_PREFIX`: this path must be a directory that contains the following
  subdirectories and files:
   - For `x86_64` systems using `glibc`:
      - `glibc/linux-x64/OpenTelemetry.AutoInstrumentation.Native.so`
      - `glibc/AdditionalDeps`
      - `glibc/store`
      - `glibc/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll`
   - For `x86_64` systems using `musl`:
       - `musl/linux-musl-x64/OpenTelemetry.AutoInstrumentation.Native.so`
       - `musl/AdditionalDeps`
       - `musl/store`
       - `musl/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll`
   - For `arm64` systems using `glibc`:
       - `glibc/linux-arm64/OpenTelemetry.AutoInstrumentation.Native.so`
       - `glibc/AdditionalDeps`
       - `glibc/store`
       - `glibc/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll`
   - For `arm` systems using `musl`:
       - `musl/linux-musl-arm64/OpenTelemetry.AutoInstrumentation.Native.so`
       - `musl/AdditionalDeps`
       - `musl/store`
       - `musl/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll`

Note that the defaults provided by the RPM and Debian packages take care of all of that, and it is not necessary to
edit `/etc/opentelemetry/otelinject.conf` or set any of the above environment variables.

Check the following for details about the auto-instrumtation agents and further configuration options:
- [Java](https://opentelemetry.io/docs/zero-code/java/agent/configuration/)
- [Node.js](https://opentelemetry.io/docs/zero-code/js/configuration/)
- [.NET](https://opentelemetry.io/docs/zero-code/dotnet/configuration/)

### `Systemd` services only

> **Note**: The following steps utilize a sample `systemd` drop-in file to activate/configure the provided agents for
> all `systemd` services via default environment variables. `Systemd` supports many options, methods, and paths for
> configuring environment variables at the system level or for individual services, and are not limited to the steps
> below. Before making any changes, it is recommended to consult the documentation specific to your Linux distribution
> or service, and check the existing configurations of the system and individual services for potential conflicts or to
> override an environment variable for a particular service. For general details about `systemd`, see the
> [`systemd` man page](https://www.freedesktop.org/software/systemd/man/index.html).

1. Copy the provided sample `systemd` drop-in file
   `/usr/lib/opentelemetry/examples/systemd/00-otelinject-instrumentation.conf` to the host's `systemd`
   [drop-in configuration directory](https://www.freedesktop.org/software/systemd/man/systemd-system.conf.html) to
   activate Auto Instrumentation for ***all*** supported applications running as `systemd` services. For example:
   ```
   mkdir -p /usr/lib/systemd/system.conf.d/ && cp /usr/lib/opentelemetry/examples/systemd/00-otelinject-instrumentation.conf /usr/lib/systemd/system.conf.d/
   ```
   This file includes the required environment variables to activate the respective agents with the default options:
   - Java:
     ```
     DefaultEnvironment="JAVA_TOOL_OPTIONS=-javaagent:/usr/lib/opentelemetry/otel-javaagent.jar"
     ```
   - Node.js:
     ```
     DefaultEnvironment="NODE_OPTIONS=-r /usr/lib/opentelemetry/otel-js/node_modules/@opentelemetry/auto-instrumentations-node/register"
     ```
   - .NET
     ```
     DefaultEnvironment="CORECLR_ENABLE_PROFILING=1"
     DefaultEnvironment="CORECLR_PROFILER={918728DD-259F-4A6A-AC2B-B85E1B658318}"
     DefaultEnvironment="CORECLR_PROFILER_PATH=/usr/lib/opentelemetry/otel-dotnet/linux-x64/OpenTelemetry.AutoInstrumentation.Native.so"
     DefaultEnvironment="DOTNET_ADDITIONAL_DEPS=/usr/lib/opentelemetry/otel-dotnet/AdditionalDeps"
     DefaultEnvironment="DOTNET_SHARED_STORE=/usr/lib/opentelemetry/otel-dotnet/store"
     DefaultEnvironment="DOTNET_STARTUP_HOOKS=/usr/lib/opentelemetry/otel-dotnet/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll"
     DefaultEnvironment="OTEL_DOTNET_AUTO_HOME=/usr/lib/opentelemetry/otel-dotnet"
     ```
2. To configure the activated agents, add/update [`DefaultEnvironment`](
   https://www.freedesktop.org/software/systemd/man/systemd-system.conf.html#DefaultEnvironment=) within the target file
   from the previous step for the desired environment variables. For example:
   ```
   cat <<EOH >> /usr/lib/systemd/system.conf.d/00-otelinject-instrumentation.conf
   DefaultEnvironment="OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4317"
   DefaultEnvironment="OTEL_RESOURCE_ATTRIBUTES=deployment.environment=my_deployment_environment"
   DefaultEnvironment="OTEL_SERVICE_NAME=my_service_name"
   EOH
   ```
   Check the following for all supported environment variables and default values:
   - [Java](https://opentelemetry.io/docs/zero-code/java/agent/configuration/)
   - [Node.js](https://opentelemetry.io/docs/zero-code/js/configuration/)
   - [.NET](https://opentelemetry.io/docs/zero-code/dotnet/configuration/)
3. Reboot the system, or run `systemctl daemon-reload` and then restart the applicable `systemd` services for any
   changes to take effect.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

### Maintainers

- [Antoine Toulme](https://github.com/atoulme), Splunk
- [Jacob Aronoff](https://github.com/jaronoff97), Omlet
- [Michele Mancioppi](https://github.com/mmanciop), Dash0
- [Bastian Krol](https://github.com/basti1302), Dash0

For more information about the maintainer role, see the [community repository](https://github.com/open-telemetry/community/blob/main/guides/contributor/membership.md#maintainer).
