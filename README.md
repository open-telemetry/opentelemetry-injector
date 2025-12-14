## ‼️ Code Freeze

We are currently in the process of porting over a large [downstream code change](https://github.com/dash0hq/dash0-operator/pull/490)
into this repository.

**Please do not start new PRs while this effort is ongoing.**

This should be probably be resolved until December 31 2025.

----

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

This method requires `root` privileges.

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
   You may want to modify this file for a couple of reasons:
   - You want to provide your own instrumentation files.

   - You want to selectively disable auto-instrumentation for a specific runtime, by setting the respective path 
     to an empty string in the configuration file `/etc/opentelemetry/otelinject.conf`.
     For example, the following file would leave JVM and Node.js auto-instrumentation active, while disabling .NET
     auto-instrumentation:
      ```
      dotnet_auto_instrumentation_agent_path_prefix=
      jvm_auto_instrumentation_agent_path=/usr/lib/opentelemetry/javaagent.jar
      nodejs_auto_instrumentation_agent_path=/usr/lib/opentelemetry/otel-js/node_modules/@opentelemetry-js/otel/instrument
      ```
   - You want to selectively enable (or disable) auto-instrumentation for a subset of programs (services) on your system. 
     For example, you may want to only enable instrumentation of services that match a specific executable path pattern, or
     to programs that do not contain certain arguments on the command line. 
     See [details on configuring the program inclusion and exclusion criteria](#details-on-configuring-the-program-inclusion-and-exclusion-criteria) for more information.

   The values set in `/etc/opentelemetry/otelinject.conf` can be overridden with environment variables.
   (This should usually not be necessary.)
   - `DOTNET_AUTO_INSTRUMENTATION_AGENT_PATH_PREFIX`: the path to the directory containing the .NET Auto Instrumentation
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
   `all_auto_instrumentation_agents_env_path` option to specify other path). You can add environment variables
   in this file - these variables will be passed to all agents' envs.

   The `auto_instrumentation_env.conf` file format is the same as other configurations:

   ```
   VARIABLE_1=some-value
   ANOTHER_VAR=other-value
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
jvm_auto_instrumentation_agent_path=/usr/lib/opentelemetry/javaagent.jar
nodejs_auto_instrumentation_agent_path=/usr/lib/opentelemetry/otel-js/node_modules/@opentelemetry-js/otel/instrument

include_paths=/app/*,/utilities/*
exclude_paths=/app/system/*
```
To give you an idea of what types of inclusion and exclusion criteria can be defined, let's
look at the following example:
```
dotnet_auto_instrumentation_agent_path_prefix=/usr/lib/opentelemetry/dotnet
jvm_auto_instrumentation_agent_path=/usr/lib/opentelemetry/javaagent.jar
nodejs_auto_instrumentation_agent_path=/usr/lib/opentelemetry/otel-js/node_modules/@opentelemetry-js/otel/instrument

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

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

### Maintainers

- [Antoine Toulme](https://github.com/atoulme), Splunk
- [Jacob Aronoff](https://github.com/jaronoff97), Omlet
- [Michele Mancioppi](https://github.com/mmanciop), Dash0
- [Bastian Krol](https://github.com/basti1302), Dash0

For more information about the maintainer role, see the [community repository](https://github.com/open-telemetry/community/blob/main/guides/contributor/membership.md#maintainer).
