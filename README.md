# opentelemetry-injector

The **OpenTelemetry Injector** Debian/RPM package
(`opentelemetry-injector`) installs OpenTelemetry Auto Instrumentation agents, the `libotelinject.so`
shared object library, and default/sample configuration files to automatically instrument applications and services to
capture and report distributed traces and metrics to the [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/)

The `opentelemetry-injector` deb/rpm package installs and supports configuration of the following Auto
Instrumentation agents:

- [Java](https://opentelemetry.io/docs/zero-code/java/)
- [Node.js](https://opentelemetry.io/docs/zero-code/js/)
- [.NET](https://opentelemetry.io/docs/zero-code/dotnet/)

## Activation and Configuration

The following methods are supported to manually activate and configure Auto Instrumentation after installation of the
`opentelemetry-injector` deb/rpm package (requires `root` privileges):

- [System-wide](#system-wide)
- [`Systemd` services only](#systemd-services-only)

> **Note**: To prevent conflicts and duplicate traces/metrics, only one method should be activated on the target system.

### System-wide

1. Add the path of the provided `/usr/lib/opentelemetry/libotelinject.so` shared object library to the
   [`/etc/ld.so.preload`](https://man7.org/linux/man-pages/man8/ld.so.8.html#FILES) file to activate Auto
   Instrumentation for ***all*** supported processes on the system. For example:
   ```
   echo /usr/lib/opentelemetry/libotelinject.so >> /etc/ld.so.preload
   ```
2. The default configuration files in the `/etc/opentelemetry/otelinject` directory includes the required environment variables
   to activate the respective agents with the default options:
   - `/etc/opentelemetry/otelinject/java.conf`:
     ```
     JAVA_TOOL_OPTIONS=-javaagent:/usr/lib/opentelemetry/javaagent.jar
     ```
   - `/etc/opentelemetry/otelinject/node.conf`:
     ```
     NODE_OPTIONS=-r /usr/lib/opentelemetry/otel-js/node_modules/@opentelemetry-js/otel/instrument
     ```
   - `/etc/opentelemetry/otelinject/dotnet.conf`:
     ```
     CORECLR_ENABLE_PROFILING=1
     CORECLR_PROFILER={918728DD-259F-4A6A-AC2B-B85E1B658318}
     CORECLR_PROFILER_PATH=/usr/lib/opentelemetry/otel-dotnet/linux-x64/OpenTelemetry.AutoInstrumentation.Native.so
     DOTNET_ADDITIONAL_DEPS=/usr/lib/opentelemetry/otel-dotnet/AdditionalDeps
     DOTNET_SHARED_STORE=/usr/lib/opentelemetry/otel-dotnet/store
     DOTNET_STARTUP_HOOKS=/usr/lib/opentelemetry/otel-dotnet/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll
     OTEL_DOTNET_AUTO_HOME=/usr/lib/opentelemetry/otel-dotnet
     ```
   Configuration of the respective agents is supported by the adding/updating the following environment variables in
   each of these files (***any environment variable not in this list will be ignored***):
   - `OTEL_EXPORTER_OTLP_ENDPOINT`
   - `OTEL_EXPORTER_OTLP_PROTOCOL`
   - `OTEL_LOGS_EXPORTER`
   - `OTEL_METRICS_EXPORTER`
   - `OTEL_RESOURCE_ATTRIBUTES`
   - `OTEL_SERVICE_NAME`

   Check the following for details about these environment variables and default values:
   - [Java](https://opentelemetry.io/docs/zero-code/java/agent/configuration/)
   - [Node.js](https://opentelemetry.io/docs/zero-code/js/configuration/)
   - [.NET](https://opentelemetry.io/docs/zero-code/dotnet/configuration/)
3. Reboot the system or restart the applications/services for any changes to take effect. The `libotelinject.so` shared
   object library will then be preloaded for all subsequent processes and inject the environment variables from the
   `/etc/opentelemetry/otelinject` configuration files for Java and Node.js processes.

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
