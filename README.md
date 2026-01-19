## OpenTelemetry Injector

The OpenTelemetry injector is a shared library (written in [Zig](https://ziglang.org/)) that is intended to be
used via the environment variable [`LD_PRELOAD`](https://man7.org/linux/man-pages/man8/ld.so.8.html#ENVIRONMENT), the
[`/etc/ld.so.preload`](https://man7.org/linux/man-pages/man8/ld.so.8.html#FILES) file, or similar mechanisms to inject
environment variables into processes at startup.

It serves two main purposes:
* Inject an OpenTelemetry auto-instrumentation agent into the process to capture and report distributed traces and
  metrics to the [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/) for supported runtimes.
* Set resource attributes automatically (for example Kubernetes related resource attributes and service related
  resource attributes in environments where this is applicable).

The injector can be used to enable automatic zero-touch instrumentation of processes.
For this to work, the injector binary needs to be bundled together with the OpenTelemetry auto-instrumentation agents
for the target runtimes.

Official RPM and DEB packages that contain the injector as well as the auto-instrumentation agents are available, and
can be downloaded from the [releases page](https://github.com/open-telemetry/opentelemetry-injector/releases).
The OpenTelemetry injector Debian/RPM packages install the OpenTelemetry auto-instrumentation agents, the
`libotelinject.so` shared object library, and a default configuration file to automatically instrument applications and
services to capture and report distributed traces and metrics to the
[OpenTelemetry Collector](https://opentelemetry.io/docs/collector/).

The `opentelemetry-injector` deb/rpm package installs and supports configuration of the following auto-instrumentation
agents:

- [Java](https://opentelemetry.io/docs/zero-code/java/)
- [Node.js](https://opentelemetry.io/docs/zero-code/js/)
- [.NET](https://opentelemetry.io/docs/zero-code/dotnet/)

## Activation and Configuration

This method requires `root` privileges.

1. Add the path of the provided `/usr/lib/opentelemetry/libotelinject.so` shared object library to the
   [`/etc/ld.so.preload`](https://man7.org/linux/man-pages/man8/ld.so.8.html#FILES) file to activate auto-
   instrumentation for ***all*** supported processes on the system. For example:
   ```
   echo /usr/lib/opentelemetry/libotelinject.so >> /etc/ld.so.preload
   ```
   Alternatively, set the environment variable `LD_PRELOAD=/usr/lib/opentelemetry/libotelinject.so` for a specific
   process to activate auto-instrumentation for that process. For example:
   ```
   LD_PRELOAD=/usr/lib/opentelemetry/libotelinject.so node myapp.js
   ```
2. The default configuration file `/etc/opentelemetry/otelinject.conf` includes the required settings, i.e. the paths to
   the respective auto-instrumentation agents per runtime:
   ```
   dotnet_auto_instrumentation_agent_path_prefix=/usr/lib/opentelemetry/dotnet
   jvm_auto_instrumentation_agent_path=/usr/lib/opentelemetry/jvm/javaagent.jar
   nodejs_auto_instrumentation_agent_path=/usr/lib/opentelemetry/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/build/src/register.js
   ```

   You can override the location of the configuration file by setting `OTEL_INJECTOR_CONFIG_FILE`.

   You may want to modify this file for a couple of reasons:
   - You want to provide your own instrumentation files.

   - You want to selectively disable auto-instrumentation for a specific runtime, by setting the respective path
     to an empty string in the configuration file.
     For example, the following file would leave JVM and Node.js auto-instrumentation active, while disabling .NET
     auto-instrumentation:
      ```
      dotnet_auto_instrumentation_agent_path_prefix=
      jvm_auto_instrumentation_agent_path=/usr/lib/opentelemetry/jvm/javaagent.jar
      nodejs_auto_instrumentation_agent_path=/usr/lib/opentelemetry/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/build/src/register.js
      ```
   - You want to selectively enable (or disable) auto-instrumentation for a subset of programs (services) on your system.
     For example, you may want to only enable instrumentation of services that match a specific executable path pattern, or
     to programs that do not contain certain arguments on the command line.
     See [details on configuring the program inclusion and exclusion criteria](#details-on-configuring-the-program-inclusion-and-exclusion-criteria) for more information.

   The values set in the configuration file can be overridden with environment variables.
   (This should usually not be necessary.)
   - `DOTNET_AUTO_INSTRUMENTATION_AGENT_PATH_PREFIX`: the path to the directory containing the .NET auto-instrumentation
     agent files
   - `JVM_AUTO_INSTRUMENTATION_AGENT_PATH`: the path to the Java auto-instrumentation agent JAR file
   - `NODEJS_AUTO_INSTRUMENTATION_AGENT_PATH`: the path to the Node.js auto-instrumentation agent registration file
   - `OTEL_INJECTOR_INCLUDE_PATHS`: a comma-separated list of glob patterns to match executable paths
   - `OTEL_INJECTOR_EXCLUDE_PATHS`: a comma-separated list of glob patterns to exclude executable paths
   - `OTEL_INJECTOR_INCLUDE_WITH_ARGUMENTS`: a comma-separated list of glob patterns to match process arguments
   - `OTEL_INJECTOR_EXCLUDE_WITH_ARGUMENTS`: a comma-separated list of glob patterns to exclude process arguments

   These aforementioned environment variables can also be used to selectively disable auto-instrumentation for a
   specific runtime, by setting the respective variable to an empty string, that is, set:
    - `DOTNET_AUTO_INSTRUMENTATION_AGENT_PATH_PREFIX=""` to disable .NET auto-instrumentation
    - `JVM_AUTO_INSTRUMENTATION_AGENT_PATH=""` to disable JVM auto-instrumentation
    - `NODEJS_AUTO_INSTRUMENTATION_AGENT_PATH=""` to disable Node.js auto-instrumentation

3. (Optional) The default env agent configuration file `/etc/opentelemetry/default_auto_instrumentation_env.conf` is empty (use
   `all_auto_instrumentation_agents_env_path` option to specify other path). Environment variables added to this file
   will be passed to all agents' environments. **NOTE**: environment variables which do not start with `OTEL_` are
   ignored.

   The `auto_instrumentation_env.conf` file format is the same as other configurations:

   ```
   OTEL_EXPORTER_OTLP_ENDPOINT=http://collector:4317
   OTEL_PROPAGATORS=tracecontext,baggage
   ```

4. Reboot the system or restart the applications/services for any changes to take effect. The `libotelinject.so` shared
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

### Environment Modifications

Here is an overview of the modifications that the injector will apply:

* It sets (or appends to) `NODE_OPTIONS` to activate the Node.js instrumentation agent.
* It adds a `-javaagent` flag to `JAVA_TOOL_OPTIONS` to activate the Java OTel SDK.
* It sets the required environment variables for activating the OpenTelemetry SDK for .NET:
    * `CORECLR_ENABLE_PROFILING`
    * `CORECLR_PROFILER`
    * `CORECLR_PROFILER_PATH`
    * `DOTNET_ADDITIONAL_DEPS`
    * `DOTNET_SHARED_STORE`
    * `DOTNET_STARTUP_HOOKS`
    * `OTEL_DOTNET_AUTO_HOME`
    * Note that the injector will not append to existing environment variables but overwrite them unconditionally if
      they are already set.
      In contrast to other runtimes, .NET does not support adding multiple agents.
* It inspects specific existing environment variables and populates `OTEL_RESOURCE_ATTRIBUTES` with additional resource
  attributes. These environment variables need to be set externally (for example by a Kubernetes operator with a mutating
  webhook on the pod spec template of the workload). If `OTEL_RESOURCE_ATTRIBUTES` is already set, the additional
  key-value pairs are appended to the existing value of `OTEL_RESOURCE_ATTRIBUTES`. Existing key-value pairs are not
  overwritten, that is if e.g. `OTEL_RESOURCE_ATTRIBUTES` already has a key-value pair for `k8s.pod.name`, the existing
  key-value pair takes priority.
  The following environment variables and resource attributes are supported:
    * `OTEL_INJECTOR_RESOURCE_ATTRIBUTES` is expected to contain key-value pairs
      (e.g. `my.resource.attribute=value,my.other.resource.attribute=another-value`) and will be added as-is.
    * `OTEL_INJECTOR_SERVICE_NAME` will be translated to `service.name`
    * `OTEL_INJECTOR_SERVICE_VERSION` will be translated to `service.version`
    * `OTEL_INJECTOR_SERVICE_NAMESPACE` will be translated to `service.namespace`
    * `OTEL_INJECTOR_K8S_NAMESPACE_NAME` will be translated to `k8s.namespace.name`
    * `OTEL_INJECTOR_K8S_POD_NAME` will be translated to `k8s.pod.name`
    * `OTEL_INJECTOR_K8S_POD_UID` will be translated to `k8s.pod.uid`
    * `OTEL_INJECTOR_K8S_CONTAINER_NAME` will be translated to `k8s.container.name`

#### Mapping Kubernetes Resource Attributes

While you can set all resource attributes with `OTEL_INJECTOR_RESOURCE_ATTRIBUTES`, the additional environment
variables controlling individual resource attributes (like `OTEL_INJECTOR_SERVICE_NAME` or
`OTEL_INJECTOR_K8S_NAMESPACE_NAME`) are useful in Kubernetes for deriving resource attributes via
[field selectors](https://kubernetes.io/docs/tasks/inject-data-application/environment-variable-expose-pod-information/#use-pod-fields-as-values-for-environment-variables),
e.g. by adding a snippet like this to the pod spec template:
```
- name: OTEL_INJECTOR_SERVICE_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.labels['app.kubernetes.io/name']
```

The following provides an overview of the intended mappings:

| Environment Variable               | Intended Mapping |
| ---------------------------------- | ---------------- |
| `OTEL_INJECTOR_K8S_NAMESPACE_NAME` | `valueFrom.fieldRef.fieldPath: metadata.namespace` |
| `OTEL_INJECTOR_K8S_POD_NAME`       | `valueFrom.fieldRef.fieldPath: metadata.name` |
| `OTEL_INJECTOR_K8S_POD_UID`        | `valueFrom.fieldRef.fieldPath: metadata.uid` |
| `OTEL_INJECTOR_K8S_CONTAINER_NAME` | The container's name (no field selector) |
| `OTEL_INJECTOR_SERVICE_NAME`       | `valueFrom.fieldRef.fieldPath: metadata.labels['app.kubernetes.io/name']` |
| `OTEL_INJECTOR_SERVICE_VERSION`    | `valueFrom.fieldRef.fieldPath: metadata.labels['app.kubernetes.io/version']` |
| `OTEL_INJECTOR_SERVICE_NAMESPACE`  | `valueFrom.fieldRef.fieldPath: metadata.labels['app.kubernetes.io/part-of']` |

The environment variable `OTEL_INJECTOR_RESOURCE_ATTRIBUTES` can be set to key-value pairs derived from the
annotations `resource.opentelemetry.io/*`, to support mapping annotations like
`resource.opentelemetry.io/service.namespace`, `resource.opentelemetry.io/service.name` to their respective resource
attributes.

See also:
* https://opentelemetry.io/docs/specs/semconv/resource/k8s/
* https://opentelemetry.io/docs/specs/semconv/non-normative/k8s-attributes/
* https://kubernetes.io/docs/tasks/inject-data-application/environment-variable-expose-pod-information/#use-pod-fields-as-values-for-environment-variables

### Configure the Injector's Logging

By default, the injector only logs errors.
Set the environment variable `OTEL_INJECTOR_LOG_LEVEL` to change the log level.
Valid values are:
- `debug`
- `info`
- `warn`
- `error` - this is the default value
- `none` - suppress all log output from the injector; this is useful for scenarios where you pipe `stderr` into another
  process and parse it.

The injector's log message will be written to `stderr` of the process that is being instrumented.

### Details on configuring the program inclusion and exclusion criteria

If you want to selectively enable (or disable) auto-instrumentation for a subset of programs (services) on your system,
the configuration file provides a couple of settings which can be used alone or in combination to produce
the desired outcome:
  - `include_paths` - A comma-separated list of glob patterns to match executable paths.
    If you do not specify anything here, the injector defaults to instrumenting **all executables**.
  - `exclude_paths` - A comma-separated list of glob patterns to exclude executable paths.
  - `include_with_arguments` - A comma-separated list of glob patterns to match process arguments.
    If you do not specify anything here, the injector defaults to instrumenting **all executables**.
  - `exclude_with_arguments` - A comma-separated list of glob patterns to exclude process arguments.

If an executable matches both an inclusion and an exclusion criterion, the exclusion takes
precedence. For example, in the following configuration, all program executables in the
`/app/system/` directory will not be instrumented, even though the `/app` directory is
included for instrumentation:
```
dotnet_auto_instrumentation_agent_path_prefix=/usr/lib/opentelemetry/dotnet
jvm_auto_instrumentation_agent_path=/usr/lib/opentelemetry/jvm/javaagent.jar
nodejs_auto_instrumentation_agent_path=/usr/lib/opentelemetry/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/build/src/register.js

include_paths=/app/*,/utilities/*
exclude_paths=/app/system/*
```
To give you an idea of what types of inclusion and exclusion criteria can be defined, let's
look at the following example:
```
dotnet_auto_instrumentation_agent_path_prefix=/usr/lib/opentelemetry/dotnet
jvm_auto_instrumentation_agent_path=/usr/lib/opentelemetry/jvm/javaagent.jar
nodejs_auto_instrumentation_agent_path=/usr/lib/opentelemetry/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/build/src/register.js

include_paths=/app/*,/utilities/*,*.exe
exclude_with_arguments=-javaagent:*,*@opentelemetry-js*,-Xmx?m
include_with_arguments=*MyProject*.jar,*app.js
```
In the example above we'll instrument:
  - any programs that run from the `/app` and `/utilities` directories
  - any programs that have an `.exe` extension
  - any programs that have a command line argument containing `MyProject`
  in the name and ending with the extension `.jar`
  - any programs that have a program argument ending in `app.js`
  - however, for all included programs, the injector **will avoid**:
    - all programs that have a command line argument starting with
    `-javaagent:`
    - all programs that have a command line argument that contains `@opentelemetry-js`
    - all `java` programs that run with a single digit megabytes of maximum memory

The example above illustrates how we avoid telemetry from unwanted applications or
injecting auto-instrumentation to programs that are already instrumented. If you have a
standard way of deploying all of your applications, you can create a default `otelinject.conf`
file that will ensure you get only the telemetry you want.

The `include_paths`, `exclude_paths`, `include_with_arguments` and `exclude_with_arguments` settings in
the configuration file are additive. This means that if you define multiple lines of these settings, the resulting
patterns list will be a union of all of the settings. This allows for easier manipulation of the configuration
file with automated tools. Essentially, you can list each include or exclude rule on a separate line.
For example, the following two configuration files have an identical outcome:
```
include_paths=/app/*,/utilities/*,*.exe
```
is the same as:
```
include_paths=/app/*
include_paths=/utilities/*
include_paths=*.exe
```

### Design

This is a short summary of how the injector works internally:
1. Find out which libc the process binds, if any. This is usually either glibc or musl.
   (Some OpenTelemetry SDKs need to be injected differently, e.g. using different binaries depending on the libc
   flavor.)
2. If the process does not bind a libc, or it cannot be identified, the injector aborts injection and hands back control
   to the host process.
3. Find the location of the `dlsym` function in the loaded libc (in memory), reading ELF metadata.
4. Use the libc's `dlsym` handle to look up more symbols in memory, in particular `__environ` and `setenv`.
5. Again, if looking up any of the symbols fails, the injector aborts injection and hands back control to the host
   process.
6. Use the pointer to the `__environ` symbol to read the current environment of the process (before adding or modifying
   any environment variables).
7. Use the pointer to the `setenv` symbol to add or modify environment variables to add and activate OpenTelemetry
   SDKs/auto-instrumentation agents for supported runtimes (e.g. `NODE_OPTIONS`, `JAVA_TOOL_OPTIONS`,
   `CORECLR_PROFILER`).
8. Use the pointer to the `setenv` symbol to add or modify `OTEL_RESOURCE_ATTRIBUTES`.

There is a much more detailed explanation of this approach, and on alternative approaches and the intricate design
constraints in [DESIGN.md](DESIGN.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

### Maintainers

- [Antoine Toulme](https://github.com/atoulme), [Splunk](https://www.splunk.com/)
- [Jacob Aronoff](https://github.com/jaronoff97), [Tero](https://www.usetero.com/)
- [Michele Mancioppi](https://github.com/mmanciop), [Dash0](https://www.dash0.com/)
- [Bastian Krol](https://github.com/basti1302), [Dash0](https://www.dash0.com/)
- [Jack Berg](https://github.com/jack-berg), [Grafana Labs](https://grafana.com/)

For more information about the maintainer role, see the [community repository](https://github.com/open-telemetry/community/blob/main/guides/contributor/membership.md#maintainer).

### Project History

The code project was initially donated by [Splunk](https://www.splunk.com/) and later replaced with another code donation
by [Dash0](https://www.dash0.com/).
