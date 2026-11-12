# Configuration

See [options](#options) for the complete configuration reference and the [README](README.md#activation-and-configuration) for activation and agent directory layouts.

## Loading order and precedence

The injector reads configuration once per process. Restart applications or services after changing configuration.

The log level and complete disablement are read from the environment before configuration-file loading. Other settings are resolved in this order:

1. Library defaults.
2. The main configuration file, selected by [OTEL_INJECTOR_CONFIG_FILE](#config_file).
3. Regular `.conf` files in the directory selected by [OTEL_INJECTOR_CONFIG_DIR](#config_dir), in alphabetical order.
4. Environment-variable overrides.

Missing or unreadable configuration files and directories are skipped. Empty file/directory selector variables use their default locations. Choosing a different main file does not disable drop-in loading.

Later scalar values replace earlier values. The include/exclude pattern lists accumulate across repeated lines and across files. An environment override replaces the entire file-derived value, rather than appending to it. An unset environment variable leaves the file-derived value unchanged. Empty and invalid values follow the rules in each option's reference entry.

Environment pre-trimming removes surrounding spaces, tabs, carriage returns (CR), and line feeds (LF) before type-specific parsing. Type-specific trimming, such as spaces, tabs, CR, and LF around integers, applies independently.

The agent paths are empty in the library defaults. Language packages can enable their agents by installing drop-in files, such as `java.conf`, in the configuration directory. Package-provided paths are not library defaults. To override a package drop-in, use a later drop-in filename or an environment variable.

## File syntax

The main file, drop-ins, and [agent environment file](#agents_env_path) use `key=value` lines:

```ini
# Enable Java instrumentation and restrict eligible executables.
jvm_auto_instrumentation_agent_path=/usr/lib/opentelemetry/jvm/javaagent.jar
include_paths=/app/*,/utilities/*
```

Blank lines are ignored. `#` begins a comment, including inside quotes. Whitespace around keys and values is trimmed before optional surrounding quotes are removed. Single-quoted values are literal. Double-quoted values unescape a backslash before `"`, `\`, `$`, or a backtick. Other backslashes are preserved. There is no shell-variable expansion. Unbalanced quotes warn and are retained literally. Unknown injector keys and malformed lines are logged and ignored.

The agent environment file contains environment-variable names rather than injector keys:

```ini
OTEL_EXPORTER_OTLP_ENDPOINT=http://collector:4317
OTEL_PROPAGATORS=tracecontext,baggage
```

Only prefixes allowed by the build are accepted, with `OTEL_` as the default. Variables from this file are applied after agent injection and overwrite existing values. Their settings configure the agents, not the injector itself. Consult the agents' configuration documentation for supported options.

## Process selection

Without include or exclude patterns, all processes are eligible. Actual instrumentation also requires a configured agent and the runtime-specific eligibility checks.

- Within one setting, patterns are ORed: any matching pattern satisfies that setting.
- Across non-empty include settings, conditions are ANDed: every configured include setting must match.
- Any exclusion takes precedence over inclusions.
- Argument patterns match individual arguments, excluding the executable name, rather than the combined command line.
- `*` matches any sequence of characters and `?` matches one character. Matching is case-sensitive and covers the entire path or argument.

For example:

```ini
include_paths=/app/*,/utilities/*,*.exe
exclude_paths=/app/system/*
include_with_arguments=*MyProject*.jar,*app.js
exclude_with_arguments=-javaagent:*,*@opentelemetry-js*,-Xmx?m
```

A process must match an executable-path inclusion and an argument inclusion. Even then, a matching excluded path or argument prevents injection. An exclusion prevents all injector environment modifications for that process, including resource attributes.

Repeated list keys accumulate. These configurations are equivalent:

```ini
include_paths=/app/*,/utilities/*,*.exe
```

```ini
include_paths=/app/*
include_paths=/utilities/*
include_paths=*.exe
```

An empty environment override such as `OTEL_INJECTOR_INCLUDE_PATHS=` clears the accumulated path-inclusion list.

<!-- BEGIN GENERATED CONFIGURATION -->

## Options

Generated from `options.yaml` using `make generate-config`. Defaults below are library defaults, not package-provided settings.

- [`OTEL_INJECTOR_DISABLED`](#disabled)
- [`OTEL_INJECTOR_LOG_LEVEL`](#log_level)
- [`OTEL_INJECTOR_CONFIG_FILE`](#config_file)
- [`OTEL_INJECTOR_CONFIG_DIR`](#config_dir)
- [`dotnet_auto_instrumentation_agent_path_prefix` / `DOTNET_AUTO_INSTRUMENTATION_AGENT_PATH_PREFIX`](#dotnet_agent_path)
- [`dotnet_auto_instrumentation_minimum_dotnet_major_version` / `DOTNET_AUTO_INSTRUMENTATION_MINIMUM_DOTNET_MAJOR_VERSION`](#dotnet_minimum_major_version)
- [`jvm_auto_instrumentation_agent_path` / `JVM_AUTO_INSTRUMENTATION_AGENT_PATH`](#jvm_agent_path)
- [`jvm_auto_instrumentation_minimum_java_major_version` / `JVM_AUTO_INSTRUMENTATION_MINIMUM_JAVA_MAJOR_VERSION`](#jvm_minimum_major_version)
- [`OTEL_INJECTOR_JAVAAGENT_EXTENSIONS`](#javaagent_extensions)
- [`nodejs_auto_instrumentation_agent_path` / `NODEJS_AUTO_INSTRUMENTATION_AGENT_PATH`](#nodejs_agent_path)
- [`python_auto_instrumentation_agent_path_prefix` / `PYTHON_AUTO_INSTRUMENTATION_AGENT_PATH_PREFIX`](#python_agent_path)
- [`ruby_auto_instrumentation_agent_path_prefix` / `RUBY_AUTO_INSTRUMENTATION_AGENT_PATH_PREFIX`](#ruby_agent_path)
- [`all_auto_instrumentation_agents_env_path`](#agents_env_path)
- [`auto_instrumentation_disabled` / `OTEL_INJECTOR_AUTO_INSTRUMENTATION_DISABLED`](#auto_instrumentation_disabled)
- [`include_paths` / `OTEL_INJECTOR_INCLUDE_PATHS`](#include_paths)
- [`exclude_paths` / `OTEL_INJECTOR_EXCLUDE_PATHS`](#exclude_paths)
- [`include_with_arguments` / `OTEL_INJECTOR_INCLUDE_WITH_ARGUMENTS`](#include_with_arguments)
- [`exclude_with_arguments` / `OTEL_INJECTOR_EXCLUDE_WITH_ARGUMENTS`](#exclude_with_arguments)
- [`OTEL_INJECTOR_RESOURCE_ATTRIBUTES`](#resource_attributes)
- [`OTEL_INJECTOR_K8S_NAMESPACE_NAME`](#k8s_namespace_name)
- [`OTEL_INJECTOR_K8S_POD_NAME`](#k8s_pod_name)
- [`OTEL_INJECTOR_K8S_POD_UID`](#k8s_pod_uid)
- [`OTEL_INJECTOR_K8S_CONTAINER_NAME`](#k8s_container_name)
- [`OTEL_INJECTOR_SERVICE_NAME`](#service_name)
- [`OTEL_INJECTOR_SERVICE_VERSION`](#service_version)
- [`OTEL_INJECTOR_SERVICE_NAMESPACE`](#service_namespace)

<a id="disabled"></a>

### `OTEL_INJECTOR_DISABLED`

Disable the injector completely, including resource-attribute injection.

- Type: `boolean`
- Default: `false`
- Environment variable: `OTEL_INJECTOR_DISABLED`
- Environment pre-trim: false
- Empty environment policy: `value`

**Empty value:** The injector remains enabled.

Values `true` and `t` (case-insensitive), and `1` disable the injector. Every other value is false. Read before configuration files and process filtering. Unlike [auto_instrumentation_disabled](#auto_instrumentation_disabled), this prevents all injector environment modifications for the process.

**Examples:**

- `OTEL_INJECTOR_DISABLED=true`

[Back to options](#options)

<a id="log_level"></a>

### `OTEL_INJECTOR_LOG_LEVEL`

Minimum severity of injector messages written to the application's stderr.

- Type: `log_level`
- Default: `error`
- Environment variable: `OTEL_INJECTOR_LOG_LEVEL`
- Environment pre-trim: false
- Empty environment policy: `value`

**Invalid value:** Log an error and retain the default level. Empty values are invalid.

**Allowed values:** `debug`, `info`, `warn`, `error`, `none`.

Values are case-insensitive. Read before configuration files and process filtering.

**Examples:**

- `OTEL_INJECTOR_LOG_LEVEL=debug`
- `OTEL_INJECTOR_LOG_LEVEL=none`

[Back to options](#options)

<a id="config_file"></a>

### `OTEL_INJECTOR_CONFIG_FILE`

Location of the main injector configuration file.

- Type: `string`
- Default: `"/etc/opentelemetry/injector/injector.conf"`
- Environment variable: `OTEL_INJECTOR_CONFIG_FILE`
- Environment pre-trim: true
- Empty environment policy: `default`

**Empty value:** Use the default configuration-file location.

A missing or unreadable file is skipped. Files from [config_dir](#config_dir) and environment overrides are still processed.

**Examples:**

- `OTEL_INJECTOR_CONFIG_FILE=/app/injector.conf`

[Back to options](#options)

<a id="config_dir"></a>

### `OTEL_INJECTOR_CONFIG_DIR`

Directory containing injector configuration drop-in files.

- Type: `string`
- Default: `"/etc/opentelemetry/injector/conf.d"`
- Environment variable: `OTEL_INJECTOR_CONFIG_DIR`
- Environment pre-trim: true
- Empty environment policy: `default`

**Empty value:** Use the default configuration-directory location.

Regular files ending in `.conf` are read in alphabetical order after [config_file](#config_file). A missing or unreadable directory is skipped.

**Examples:**

- `OTEL_INJECTOR_CONFIG_DIR=/app/injector.conf.d`

[Back to options](#options)

<a id="dotnet_agent_path"></a>

### `dotnet_auto_instrumentation_agent_path_prefix` / `DOTNET_AUTO_INSTRUMENTATION_AGENT_PATH_PREFIX`

Directory containing the .NET auto-instrumentation agent files.

- Type: `string`
- Default: `""`
- File key: `dotnet_auto_instrumentation_agent_path_prefix`
- Repeated file keys: `replace`
- Environment variable: `DOTNET_AUTO_INSTRUMENTATION_AGENT_PATH_PREFIX`
- Environment pre-trim: true
- Empty environment policy: `value`
- Environment override: replaces file values when successfully parsed

**Empty value:** Disable .NET auto-instrumentation.

Must contain the architecture-specific native library, AdditionalDeps, store, and net startup-hook files beneath glibc and musl directories. See the [agent layout guide](README.md#activation-and-configuration). An empty path disables only .NET instrumentation, not [resource-attribute injection](#resource_attributes).

**Examples:**

- `dotnet_auto_instrumentation_agent_path_prefix=/usr/lib/opentelemetry/dotnet`

[Back to options](#options)

<a id="dotnet_minimum_major_version"></a>

### `dotnet_auto_instrumentation_minimum_dotnet_major_version` / `DOTNET_AUTO_INSTRUMENTATION_MINIMUM_DOTNET_MAJOR_VERSION`

Minimum .NET major version eligible for auto-instrumentation.

- Type: `uint32`
- Default: `8`
- File key: `dotnet_auto_instrumentation_minimum_dotnet_major_version`
- Repeated file keys: `replace`
- Environment variable: `DOTNET_AUTO_INSTRUMENTATION_MINIMUM_DOTNET_MAJOR_VERSION`
- Environment pre-trim: false
- Empty environment policy: `value`
- Type-specific whitespace trimming: spaces, tabs, CR, and LF around the integer
- Environment override: replaces file values when successfully parsed

**Invalid value:** Warn and retain the previously resolved value. Empty values are invalid.

Accepts decimal integers from 0 through 4294967295, trimming surrounding spaces, tabs, carriage returns, and line feeds. Applies when the application's `runtimeconfig.json` identifies a runtime version. Distributions supporting older .NET versions can lower this threshold.

**Examples:**

- `dotnet_auto_instrumentation_minimum_dotnet_major_version=8`
- `dotnet_auto_instrumentation_minimum_dotnet_major_version=6`

[Back to options](#options)

<a id="jvm_agent_path"></a>

### `jvm_auto_instrumentation_agent_path` / `JVM_AUTO_INSTRUMENTATION_AGENT_PATH`

Path to the Java auto-instrumentation agent JAR.

- Type: `string`
- Default: `""`
- File key: `jvm_auto_instrumentation_agent_path`
- Repeated file keys: `replace`
- Environment variable: `JVM_AUTO_INSTRUMENTATION_AGENT_PATH`
- Environment pre-trim: true
- Empty environment policy: `value`
- Environment override: replaces file values when successfully parsed

**Empty value:** Disable JVM auto-instrumentation.

An empty path disables only JVM instrumentation, not [resource-attribute injection](#resource_attributes). It can disable Java for one process without changing shared configuration.

**Examples:**

- `jvm_auto_instrumentation_agent_path=/usr/lib/opentelemetry/jvm/javaagent.jar`
- `jvm_auto_instrumentation_agent_path=`

[Back to options](#options)

<a id="jvm_minimum_major_version"></a>

### `jvm_auto_instrumentation_minimum_java_major_version` / `JVM_AUTO_INSTRUMENTATION_MINIMUM_JAVA_MAJOR_VERSION`

Minimum Java major version eligible for auto-instrumentation.

- Type: `uint32`
- Default: `8`
- File key: `jvm_auto_instrumentation_minimum_java_major_version`
- Repeated file keys: `replace`
- Environment variable: `JVM_AUTO_INSTRUMENTATION_MINIMUM_JAVA_MAJOR_VERSION`
- Environment pre-trim: false
- Empty environment policy: `value`
- Type-specific whitespace trimming: spaces, tabs, CR, and LF around the integer
- Environment override: replaces file values when successfully parsed

**Invalid value:** Warn and retain the previously resolved value. Empty values are invalid.

Accepts decimal integers from 0 through 4294967295, trimming surrounding spaces, tabs, carriage returns, and line feeds. Set to `0` to skip Java version detection. If the Java version cannot be determined, injection is skipped. Distributions supporting older Java versions can lower this threshold.

**Examples:**

- `jvm_auto_instrumentation_minimum_java_major_version=8`
- `jvm_auto_instrumentation_minimum_java_major_version=6`
- `jvm_auto_instrumentation_minimum_java_major_version=0`

[Back to options](#options)

<a id="javaagent_extensions"></a>

### `OTEL_INJECTOR_JAVAAGENT_EXTENSIONS`

Java agent extension paths to append to OTEL_JAVAAGENT_EXTENSIONS.

- Type: `string`
- Default: `""`
- Environment variable: `OTEL_INJECTOR_JAVAAGENT_EXTENSIONS`
- Environment pre-trim: false
- Empty environment policy: `value`

**Empty value:** Leave OTEL_JAVAAGENT_EXTENSIONS unchanged.

Comma-separated paths. Whitespace is preserved, empty entries are ignored, and paths are compared exactly to avoid duplicates. Existing entries remain first. If no new path is appended, the existing value is left unchanged.

Applied after the [agent environment file](#agents_env_path), so its `OTEL_JAVAAGENT_EXTENSIONS` value is included in the merge. Requires a non-empty [JVM agent path](#jvm_agent_path) and JVM instrumentation not disabled by [auto_instrumentation_disabled](#auto_instrumentation_disabled). Unlike Java agent injection, this does not check agent JAR accessibility or the minimum Java version.

**Examples:**

- `OTEL_INJECTOR_JAVAAGENT_EXTENSIONS=/extensions/custom.jar,/extensions/another.jar`

[Back to options](#options)

<a id="nodejs_agent_path"></a>

### `nodejs_auto_instrumentation_agent_path` / `NODEJS_AUTO_INSTRUMENTATION_AGENT_PATH`

Path to the Node.js auto-instrumentation registration file.

- Type: `string`
- Default: `""`
- File key: `nodejs_auto_instrumentation_agent_path`
- Repeated file keys: `replace`
- Environment variable: `NODEJS_AUTO_INSTRUMENTATION_AGENT_PATH`
- Environment pre-trim: true
- Empty environment policy: `value`
- Environment override: replaces file values when successfully parsed

**Empty value:** Disable Node.js auto-instrumentation.

An empty path disables only Node.js instrumentation, not [resource-attribute injection](#resource_attributes).

**Examples:**

- `nodejs_auto_instrumentation_agent_path=/usr/lib/opentelemetry/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/build/src/register.js`

[Back to options](#options)

<a id="python_agent_path"></a>

### `python_auto_instrumentation_agent_path_prefix` / `PYTHON_AUTO_INSTRUMENTATION_AGENT_PATH_PREFIX`

Directory containing the Python auto-instrumentation packages.

- Type: `string`
- Default: `""`
- File key: `python_auto_instrumentation_agent_path_prefix`
- Repeated file keys: `replace`
- Environment variable: `PYTHON_AUTO_INSTRUMENTATION_AGENT_PATH_PREFIX`
- Environment pre-trim: true
- Empty environment policy: `value`
- Environment override: replaces file values when successfully parsed

**Empty value:** Disable Python auto-instrumentation.

Must contain `glibc` and `musl` directories. The matching directory is prepended to `PYTHONPATH`. Python is opt-in because injecting packages can cause dependency conflicts. An empty path disables only Python instrumentation, not [resource-attribute injection](#resource_attributes).

**Examples:**

- `python_auto_instrumentation_agent_path_prefix=/usr/lib/opentelemetry/python`

[Back to options](#options)

<a id="ruby_agent_path"></a>

### `ruby_auto_instrumentation_agent_path_prefix` / `RUBY_AUTO_INSTRUMENTATION_AGENT_PATH_PREFIX`

Directory containing the Ruby auto-instrumentation gem bundle.

- Type: `string`
- Default: `""`
- File key: `ruby_auto_instrumentation_agent_path_prefix`
- Repeated file keys: `replace`
- Environment variable: `RUBY_AUTO_INSTRUMENTATION_AGENT_PATH_PREFIX`
- Environment pre-trim: true
- Empty environment policy: `value`
- Environment override: replaces file values when successfully parsed

**Empty value:** Disable Ruby auto-instrumentation.

Must contain `glibc` and `musl` gem-home directories with the `opentelemetry-auto-instrumentation.rb` entry point. Prefixes containing whitespace are rejected during injection. An empty path disables only Ruby instrumentation, not [resource-attribute injection](#resource_attributes).

**Examples:**

- `ruby_auto_instrumentation_agent_path_prefix=/usr/lib/opentelemetry/ruby`

[Back to options](#options)

<a id="agents_env_path"></a>

### `all_auto_instrumentation_agents_env_path`

File containing environment variables to pass to all agents.

- Type: `string`
- Default: `"/etc/opentelemetry/injector/default_env.conf"`
- File key: `all_auto_instrumentation_agents_env_path`
- Repeated file keys: `replace`

**Empty value:** Do not load an agent environment file.

Uses the same `key=value` syntax as `injector.conf`. Missing or unreadable files are skipped. Only `OTEL_` variables are accepted by default. Additional prefixes require a custom build using `-Dallowed-env-var-prefixes`. Variables from this file overwrite existing process values.

**Examples:**

- `all_auto_instrumentation_agents_env_path=/app/default_env.conf`

[Back to options](#options)

<a id="auto_instrumentation_disabled"></a>

### `auto_instrumentation_disabled` / `OTEL_INJECTOR_AUTO_INSTRUMENTATION_DISABLED`

Runtimes for which auto-instrumentation is disabled.

- Type: `runtime_list`
- Default: `[]`
- File key: `auto_instrumentation_disabled`
- Repeated file keys: `replace`
- Environment variable: `OTEL_INJECTOR_AUTO_INSTRUMENTATION_DISABLED`
- Environment pre-trim: true
- Empty environment policy: `value`
- Environment override: replaces file values when successfully parsed

**Empty value:** Do not disable any runtime through this setting.

**Invalid value:** Warn and ignore unknown runtime names.

Use `*` alone to disable all runtimes, or a comma-separated list of `dotnet`, `jvm`, `nodejs`, `python`, or `ruby`. Names are case-sensitive.

For example, `auto_instrumentation_disabled=dotnet,python` leaves JVM, Node.js, and Ruby instrumentation eligible. An empty [agent path](#jvm_agent_path) also disables that runtime.

Resource attributes may still be injected. Use [OTEL_INJECTOR_DISABLED](#disabled) to disable the injector completely, including resource-attribute injection.

**Examples:**

- `auto_instrumentation_disabled=*`
- `auto_instrumentation_disabled=dotnet,python`

[Back to options](#options)

<a id="include_paths"></a>

### `include_paths` / `OTEL_INJECTOR_INCLUDE_PATHS`

Executable path patterns eligible for instrumentation.

- Type: `glob_list`
- Default: `[]`
- File key: `include_paths`
- Repeated file keys: `append`
- Environment variable: `OTEL_INJECTOR_INCLUDE_PATHS`
- Environment pre-trim: true
- Empty environment policy: `value`
- Environment override: replaces file values when successfully parsed

**Empty value:** No executable-path inclusion restriction.

Comma-separated glob patterns. Items are trimmed and empty items are ignored. `*` matches any sequence and `?` matches one character.

Any matching pattern satisfies this setting. When [include_with_arguments](#include_with_arguments) is also non-empty, both settings must match. [Path exclusions](#exclude_paths) and [argument exclusions](#exclude_with_arguments) take precedence.

**Examples:**

- `include_paths=/app/*,/utilities/*`

[Back to options](#options)

<a id="exclude_paths"></a>

### `exclude_paths` / `OTEL_INJECTOR_EXCLUDE_PATHS`

Executable path patterns excluded from instrumentation.

- Type: `glob_list`
- Default: `[]`
- File key: `exclude_paths`
- Repeated file keys: `append`
- Environment variable: `OTEL_INJECTOR_EXCLUDE_PATHS`
- Environment pre-trim: true
- Empty environment policy: `value`
- Environment override: replaces file values when successfully parsed

**Empty value:** No executable-path exclusions.

Comma-separated glob patterns. Items are trimmed and empty items are ignored. `*` matches any sequence and `?` matches one character.

Any matching pattern excludes the process, even when [include_paths](#include_paths) matches.

**Examples:**

- `exclude_paths=/app/system/*`

[Back to options](#options)

<a id="include_with_arguments"></a>

### `include_with_arguments` / `OTEL_INJECTOR_INCLUDE_WITH_ARGUMENTS`

Process argument patterns eligible for instrumentation.

- Type: `glob_list`
- Default: `[]`
- File key: `include_with_arguments`
- Repeated file keys: `append`
- Environment variable: `OTEL_INJECTOR_INCLUDE_WITH_ARGUMENTS`
- Environment pre-trim: true
- Empty environment policy: `value`
- Environment override: replaces file values when successfully parsed

**Empty value:** No process-argument inclusion restriction.

Comma-separated glob patterns. Items are trimmed and empty items are ignored. `*` matches any sequence and `?` matches one character.

Patterns match individual arguments. Any matching argument satisfies this setting. When [include_paths](#include_paths) is also non-empty, both settings must match. [Path exclusions](#exclude_paths) and [argument exclusions](#exclude_with_arguments) take precedence.

**Examples:**

- `include_with_arguments=*MyProject*.jar,*app.js`

[Back to options](#options)

<a id="exclude_with_arguments"></a>

### `exclude_with_arguments` / `OTEL_INJECTOR_EXCLUDE_WITH_ARGUMENTS`

Process argument patterns excluded from instrumentation.

- Type: `glob_list`
- Default: `[]`
- File key: `exclude_with_arguments`
- Repeated file keys: `append`
- Environment variable: `OTEL_INJECTOR_EXCLUDE_WITH_ARGUMENTS`
- Environment pre-trim: true
- Empty environment policy: `value`
- Environment override: replaces file values when successfully parsed

**Empty value:** No process-argument exclusions.

Comma-separated glob patterns. Items are trimmed and empty items are ignored. `*` matches any sequence and `?` matches one character.

Patterns match individual arguments. Any matching argument excludes the process, even when [include_with_arguments](#include_with_arguments) matches.

**Examples:**

- `exclude_with_arguments=-javaagent:*,*@opentelemetry-js*`

[Back to options](#options)

<a id="resource_attributes"></a>

### `OTEL_INJECTOR_RESOURCE_ATTRIBUTES`

Additional resource attributes to append to OTEL_RESOURCE_ATTRIBUTES.

- Type: `string`
- Default: `""`
- Environment variable: `OTEL_INJECTOR_RESOURCE_ATTRIBUTES`
- Environment pre-trim: false
- Empty environment policy: `value`

**Empty value:** Do not add any resource attributes.

Comma-separated `key=value` pairs. Keys are trimmed and empty keys are ignored. Values are preserved.

Resource keys already in `OTEL_RESOURCE_ATTRIBUTES` win over this setting. These values in turn win over individual mappings such as [OTEL_INJECTOR_SERVICE_NAME](#service_name). Within this additional key-value list, the first occurrence of a key wins.

Setting [auto_instrumentation_disabled](#auto_instrumentation_disabled) does not disable resource-attribute injection. Use [OTEL_INJECTOR_DISABLED](#disabled) to prevent all injector environment modifications. See the [Kubernetes mapping example](README.md#mapping-kubernetes-resource-attributes) for deriving individual values from pod fields.

**Examples:**

- `OTEL_INJECTOR_RESOURCE_ATTRIBUTES=service.name=my-service,deployment.environment.name=production`

[Back to options](#options)

<a id="k8s_namespace_name"></a>

### `OTEL_INJECTOR_K8S_NAMESPACE_NAME`

Kubernetes namespace name to add to OTEL_RESOURCE_ATTRIBUTES.

- Type: `string`
- Default: `""`
- Environment variable: `OTEL_INJECTOR_K8S_NAMESPACE_NAME`
- Environment pre-trim: false
- Empty environment policy: `value`

**Empty value:** Add the resource attribute with an empty value if the variable is set.

**Resource attribute:** `k8s.namespace.name`. See [resource-attribute precedence](#resource_attributes) for interactions with other inputs.

**Examples:**

- `OTEL_INJECTOR_K8S_NAMESPACE_NAME=default`

[Back to options](#options)

<a id="k8s_pod_name"></a>

### `OTEL_INJECTOR_K8S_POD_NAME`

Kubernetes pod name to add to OTEL_RESOURCE_ATTRIBUTES.

- Type: `string`
- Default: `""`
- Environment variable: `OTEL_INJECTOR_K8S_POD_NAME`
- Environment pre-trim: false
- Empty environment policy: `value`

**Empty value:** Add the resource attribute with an empty value if the variable is set.

**Resource attribute:** `k8s.pod.name`. See [resource-attribute precedence](#resource_attributes) for interactions with other inputs.

**Examples:**

- `OTEL_INJECTOR_K8S_POD_NAME=my-pod`

[Back to options](#options)

<a id="k8s_pod_uid"></a>

### `OTEL_INJECTOR_K8S_POD_UID`

Kubernetes pod UID to add to OTEL_RESOURCE_ATTRIBUTES.

- Type: `string`
- Default: `""`
- Environment variable: `OTEL_INJECTOR_K8S_POD_UID`
- Environment pre-trim: false
- Empty environment policy: `value`

**Empty value:** Add the resource attribute with an empty value if the variable is set.

**Resource attribute:** `k8s.pod.uid`. See [resource-attribute precedence](#resource_attributes) for interactions with other inputs.

**Examples:**

- `OTEL_INJECTOR_K8S_POD_UID=123e4567-e89b-12d3-a456-426614174000`

[Back to options](#options)

<a id="k8s_container_name"></a>

### `OTEL_INJECTOR_K8S_CONTAINER_NAME`

Kubernetes container name to add to OTEL_RESOURCE_ATTRIBUTES.

- Type: `string`
- Default: `""`
- Environment variable: `OTEL_INJECTOR_K8S_CONTAINER_NAME`
- Environment pre-trim: false
- Empty environment policy: `value`

**Empty value:** Add the resource attribute with an empty value if the variable is set.

**Resource attribute:** `k8s.container.name`. See [resource-attribute precedence](#resource_attributes) for interactions with other inputs.

**Examples:**

- `OTEL_INJECTOR_K8S_CONTAINER_NAME=my-container`

[Back to options](#options)

<a id="service_name"></a>

### `OTEL_INJECTOR_SERVICE_NAME`

Service name to add to OTEL_RESOURCE_ATTRIBUTES.

- Type: `string`
- Default: `""`
- Environment variable: `OTEL_INJECTOR_SERVICE_NAME`
- Environment pre-trim: false
- Empty environment policy: `value`

**Empty value:** Add the resource attribute with an empty value if the variable is set.

**Resource attribute:** `service.name`. See [resource-attribute precedence](#resource_attributes) for interactions with other inputs.

**Examples:**

- `OTEL_INJECTOR_SERVICE_NAME=my-service`

[Back to options](#options)

<a id="service_version"></a>

### `OTEL_INJECTOR_SERVICE_VERSION`

Service version to add to OTEL_RESOURCE_ATTRIBUTES.

- Type: `string`
- Default: `""`
- Environment variable: `OTEL_INJECTOR_SERVICE_VERSION`
- Environment pre-trim: false
- Empty environment policy: `value`

**Empty value:** Add the resource attribute with an empty value if the variable is set.

**Resource attribute:** `service.version`. See [resource-attribute precedence](#resource_attributes) for interactions with other inputs.

**Examples:**

- `OTEL_INJECTOR_SERVICE_VERSION=1.0.0`

[Back to options](#options)

<a id="service_namespace"></a>

### `OTEL_INJECTOR_SERVICE_NAMESPACE`

Service namespace to add to OTEL_RESOURCE_ATTRIBUTES.

- Type: `string`
- Default: `""`
- Environment variable: `OTEL_INJECTOR_SERVICE_NAMESPACE`
- Environment pre-trim: false
- Empty environment policy: `value`

**Empty value:** Add the resource attribute with an empty value if the variable is set.

**Resource attribute:** `service.namespace`. See [resource-attribute precedence](#resource_attributes) for interactions with other inputs.

**Examples:**

- `OTEL_INJECTOR_SERVICE_NAMESPACE=my-team`

[Back to options](#options)

<!-- END GENERATED CONFIGURATION -->
