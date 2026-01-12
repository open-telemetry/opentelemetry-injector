## OpenTelemetry Injector Design

The OpenTelemetry injector is a shared library (written in [Zig](https://ziglang.org/)) that is intended to be
used via the environment variable [`LD_PRELOAD`](https://man7.org/linux/man-pages/man8/ld.so.8.html#ENVIRONMENT), the
[`/etc/ld.so.preload`](https://man7.org/linux/man-pages/man8/ld.so.8.html#FILES) file, or similar mechanisms to inject
environment variables into processes at startup.

See [README.me](README.md) for a general purpose overview.
This document focusses on the technical design and the design constraints leading to the approach taken by this project.

In the remainder of this document `LD_PRELOAD` and `/etc/ld.so.preload` are used interchangeably.

## Design Constraints

* The injector must work seamlessly with the two dominant CPU architectures found with Linux workloads, x86_64 and
  arm64.
  It should be possible to extend the support to other CPU architectures later on.
  (Note: When distributed as a container image, it is trivial to achieve this, by compiling the injector binary for all
  supported CPU architectures and building a multi-platform image.)
* The injector must work seamlessly with both libc flavors, the [GNU C library](https://sourceware.org/glibc/) (or glibc
  for short) and [musl](https://musl.libc.org/).
  When adding the injector via `LD_PRELOAD` to systems where the libc flavor is not known ahead of time, this is
  crucial to ensure that the injector does not crash executables at startup.
  Specifically in a Kubernetes context, tools like Kubernetes operators do typically not know the libc flavor of
  container images used in pods, and have no reliable way of finding out.
* The injector must be able to inject environment variables into any dynamically linked, ELF-based Linux executable.
  Other formats besides ELF (which are very rare on Linux) are out of scope.
  Other operating systems (Windows, macOS, BSD, etc.) are out of scope as well.
* While it is out of scope for this project to inject environment variables into freestanding executables, libc-free
  executables, or statically linked executables etc. (only dynamically linked executables are supported because of the
  reliance on `LD_PRELOAD`), the injector must not break these types of executables.
  That is, using the injector as a system-wide `LD_PRELOAD` setting must not prohibit any executable on the system from
  starting correctly.
* As an extension, to the previous point, it is also not acceptable to interfere with the environment of executables
  except for the desired modifications.
  For example, if the executable reads `JAVA_TOOL_OPTIONS` at startup, it must see the modified value that includes
  the `-javaagent` flag added by the injector.
  But if the executable reads an unrelated environment variable like `PATH`, it must see exactly what it would see
  without the injector being present.
* In general, the injector must not alter the observed behavior of the executable, except for the desired modifications.
* In short, it must always be safe to set up the injector as a system-wide `LD_PRELOAD` hook.
* As a stretch goal, it would be desirable to not pollute the environment with unrelated environment variables, that is,
  do not set `NODE_OPTIONS` for a JVM process, or `JAVA_TOOL_OPTIONS` for a Node.js process, etc.
  The currently implemented approach does not achieve this.
  All known approaches that satisfy this have other, more severe limitations.

Note: Statically linked executables will not be affected by `LD_PRELOAD` at all, but there are
[binaries](#dynamically-linked-libc-free-binaries) that are dynamically linked and affected by `LD_PRELOAD`, but do
_not_ link against any libc.
Binaries of this type require special consideration.

## Design

The approach taken by the OpenTelemetry injector is as follows:

* It assumes it is added as a shared object to the process via `LD_PRELOAD` or `/etc/ld.so.preload`.
  When set up this way, whenever a Linux process starts up that is subject to dynamic linking (that is, it uses shared
  objects like the C standard library `libc`), the OpenTelemetry injector code is loaded at process startup.
* The OpenTelemetry injector (`libotelinject.so`), via ELF's `.init_array`, executes the following steps at the startup
  of the executable, that is, before the actual `main()` function of the executable is called:
* Find out which libc flavor we are dealing with - glibc or musl:
    * Read the ELF header section from `/proc/self/exe`, and the dynamic symbol table in particular, then find the
      `DT_NEEDED` entries in the dynamic symbol section.
    * Inspect the `DT_NEEDED` entries.
      If one of them contains the string `musl`, we know that this binary was linked against musl libc at build time.
      If one of them contains `libc.so.6`, we know that this binary was linked against glibc at build time.
* Next, we try to find the location of the [`dlsym`](https://www.man7.org/linux/man-pages/man3/dlsym.3.html) symbol in
  the mapped memory of the process.
  This happens as follows:
    * Read `/proc/self/maps` and look for a memory segment that contains the libc shared object.
      The libc name found in the previous step facilitates this.
      Once a matching memory segment is found, check whether it contains the `dlsym` symbol, i.e. look up the memory
      address of that symbol.
      If this lookup is successful, we can use it to actually call the `dlsym` function (without declaring a direct
      dependency on it).
* Finally, use `dlsym` to find the location of the `setenv` and the `__environ` symbol.
* Use the `__environ` symbol to read the existing environment variables for the process.
* Use `setenv` to set or modify the required environment variables (`NODE_OPTIONS`, `JAVA_TOOL_OPTIONS`,
  `OTEL_RESOURCE_ATTRIBUTES` etc.)

If this sounds convoluted, and more complex than it should be, read on!
The next section outlines which alternative approaches have been considered, and the shortcomings of each of them.

## Alternative Approaches

### Using `setenv` and `getenv` directly

A very simple approach to implementing an injector would be to just declare a dependency on symbools like `setenv` and
`getenv`.
This would require that the injector is compiled and linked against a specific libc flavor, either glibc or musl.
When used as an `LD_PRELOAD` hook on a system that uses a different libc flavor, this would crash all processes at
startup.
For example, if the injector would be linked against musl, the injector binary would explicitly request musl in its ELF
header (e.g. `libc.musl-aarch64.so.1`).
When added via `LD_PRELOAD` on a glibc based system, the kernel would look for this dependency, fail to find it, and
refuse to start the executable.

For the same reason, we can also not declare a direct dependency on `dlsym`.

Another alternative would be to really only declare a dependency on these symbols (e.g. via `extern`) and not provide
it at compile time, relying on the linker/loader to resolve the symbol at process startup.
This way, the injector would work on glibc- as well as musl-based systems, as long as the symbols are present in memory
at process startup.
However, this will approach would crash [binaries](#dynamically-linked-libc-free-binaries) that are subject to dynamic
linking but do not link against any libc.
At startup, the linker/loader would not be able to resolve the symbols the injector declares as dependencies, and refuse
to start the executable.

### Export `getenv`

Instead of trying to depend on existing symbols from libc, the injector could _export_ its own `getenv` symbol to
override libc's `getenv` function.
When a process starts up, and the executable declares that it needs the `getenv` function, the dynamic linker/loader
finds the `getenv` symbol provided by the injector first.
In effect, whenever the process calls `getenv`, the injector's `getenv` implementation is called instead of the original
libc version of that function.
For environment variables that the injector does not care about, it returns the original value, and for the
"interesting" environment variables, it modifies the value on the fly before returning it.
In fact, this strategy would get us 99% of the way, and it has been used in previous incarnations of the OpenTelemetry injector.

To make this work, the injector needs to be able to read the process environment on its own, since it cannot rely
on libc functionality to get the enviroment.
(And it obviously needs to know the environment to be able to return the original values for environment variables it
does not want to modifiy and also for appending to the ones it needs to modify, if they are already set.)
One way of doing that is to declare a dependency on the `__environ` symbol (e.g. `extern char **__environ`), which is a
pointer to the in-memory storage of the environment.
Again, this will crash [binaries](#dynamically-linked-libc-free-binaries) that are subject to dynamic linking but do not
link against any libc.
At startup, the linker/loader would not be able to resolve the `__environ` symbol, and refuse to start the executable.

Another way of getting the environment would be to read the file `/proc/self/environ`, which contains the environment
variables as a null-separated list of `KEY=VALUE` strings.
This would solve the problem of the missing `__environ` symbol at startup.

Unfortunately, there are still isssues with the approach to export `getenv`:

* Most importantly, a lot of runtimes do not use `getenv` consistently to read environment variables.
  Instead, they declare a dependency on the `__environ` symbol (or one of its aliases like `_environ` or `environ`)
  directly and read directly from the content of this symbol.
  This includes the JVM, Python, and .NET.
  Often, this way of reading environment variables without using `getenv` is only is used for in-runtime lookups of
  environment variables.
  That is, at startup, the native code the runtime is implemented in will actually use `getenv` -- for example, the JVM
  reads `JAVA_TOOL_OPTIONS` via `getenv`, the common language runtime for .NET reads `CORECLR_ENABLE_PROFILING`,
  `CORECLR_PROFILER` etc. via `getenv` and so on.
  But once the runtime is up and running, it will use the content of the `__environ` array (or a copy of that content)
  directly for any further lookups of environment variables that are made within Java or .NET code.
  This renders the `getenv` override ineffective for injecting `OTEL_RESOURCE_ATTRIBUTES` into the JVM, the CLR or
  Python.
  (The reason for this is that `OTEL_RESOURCE_ATTRIBUTES` is read within the runtime by the respective OpenTelemetry
  SDK, not by the runtime implementation itself.
  For the JVM there would be a workaround for `OTEL_RESOURCE_ATTRIBUTES` by adding a `-Dotel.resource.attributes`
  to `JAVA_TOOL_OPTIONS`, but there is no generalized workaround that also works for .NET and Python.)
* When using the approach of exporting `getenv`, one has to also take care of modifications of the environment at
  runtime.
  Imagine the following sequence of events:
    * the process calls `getenv("SOME_ENV_VAR"`),
    * the injector's `getenv` override returns the value of `SOME_ENV_VAR` from its own memory, which has been
      populated (maybe from `__environ` or from `/proc/self/environ` or otherwise) at startup,
    * the process later modifies the environment variable (e.g. calls `setenv("SOME_ENV_VAR", "new-value", 1)`,
    * the process calls `getenv("SOME_ENV_VAR"`) again,
    * the injector's `getenv` override must make sure to return the new value.
  This is trivial when declaring a dependency on `__environ` (which has its own problems), but not when
  initializing the environment from `/proc/self/environ` at startup, in which case it would probably be required to also
  override `setenv`, `putenv`, `clearenv` etc.

### Export the `__environ` symbol

The backing in-memory storage for `getenv`, `setenv` etc. is the symbol `__environ`, a pointer to a list of pointers,
each of which is a string in the form of `KEY=VALUE`.
What if, instead of exporting `getenv`, the injector would export the `__environ` symbol (and its aliases, that is,
`_environ` and `environ`)?
It could initialize that array the same way as libc would do it, by reading the file `/proc/self/environ` (which is
a null-separated list of `KEY=VALUE` strings) at startup, and then populate its own `__environ` array from that.
Then, if the executable declares a dependency on `__environ` (or `_environ` or `environ`), the injector's `__environ`
array would be used instead of the libc version.
This would solve all issues mentioned in the section [export `getenv`](#export-getenv) -- no `extern` dependency on any
libc symbol, consistent behavior when `__environ` is modified after startup, no problems injecting into code that
bypasses `getenv`.
Theoretically, this should also work for the `__environ` symbol used in the libc's implementation of `getenv`, `setenv`
etc., because of how the symbol resolution of the linker works.

However, after some experiments, this approach turned out to be unfeasible.
An injector with this approach can successfully inject environment variables into _some_ binaries.
In particular, this worked with some shells.
Since shells are used as entrypoints in many container images, it may seem as if this works reliably, because the
injector modifies the environment of the shell entrypoint successfully, and then any process started from that shell
inherits the modified environment.
However, when using container images which use the binary (e.g. the JVM, Node.js, ...) as their entrypoint directly,
without using a shell entrypoint, this approach fails to work for some binaries.
The reason is that libc will override the content of `__environ` with the value of `envp` in its own initialization
procedure, or in the `execve` system call, that is, after the injector has set up the `__environ` content, but before
the application's `main()` function is called.
There is currently no known way an `LD_PRELOAD`-based injector can hook into this process.

### Look up `setenv` and `__environ` at runtime, and still override `getenv`

With the current approach outlined in the [design](#design) section, we can solve all requirements without breaking
any executables.
But since the approach makes its modifications via `setenv`, it will pollute the environment of all processes with
all environment variables it sets, even if they are not relevant for the specific binary.
That is, all process will see `NODE_OPTIONS`, `JAVA_TOOL_OPTIONS` and all the .NET related environment variables, even
if it is not a Node.js, JVM or .NET process.

Could we not export and override libc's `getenv` and handle the injection of `NODE_OPTIONS`, `JAVA_TOOL_OPTIONS` etc.
(which are read via `getenv`) that way, and only use `setenv` for injecting `OTEL_RESOURCE_ATTRIBUTES` (which is not
read via `getenv` by some runtimes, as explained above)?
That would give us all the benefits of the `getenv` override approach (less environment variable pollution), without any
of the drawbacks described in the section [export `getenv`](#export-getenv).

There are two issues that make this particular strategy prohibitive:

1. On most modern distributions, the actual libc file (say, `libc.so.6`) contains `getenv`, `setenv` etc. and also
   `dlsym`.
   However, on older distributions (Debian bullseye being one example), `dlsym` is actually provided by a separate file.
   Nearly all of libc's functions are provided by `libc-2.31.so` or similar (which is symlinked as `libc.so.6`), but
   that file does not contain the symbols `dlsym`, `dlopen` etc. Instead, these symbols are provided by `libdl-2.31.so`.
   Most interesting binaries will link both, libc and libdl, but of course binaries can also only link libc, if they
   do not depend on libdl at all.
   The best thing the injector could do in this case is to stand down.
   It will not crash the executable, since there is no linking error.
   But since it wasn't able to find `dlsym`, it can also not lookup `__environ`, hence it has no knowledge of the
   current environment, hence its `getenv` override will not be able to return any values for any environment variable.
   Effectively, this would start the executable with an empty environment, which is not acceptable.
   This could potentially be worked around by looking up `__environ` directly without using `dlsym`, or by falling back
   to backfilling the environment by reading `/proc/self/environ`.
   However, the next issue is even more severe.
2. There can be shared objects that look up environment variables very early in the startup process, even before the
   injector had a chance to run its initialization code.
   A prominent example is OpenSSL, which is used by many runtimes and applications.
   The OpenSSL code, when run on arm64 CPUS, reads `OPENSSL_armcap` (a capabilities bitmaks) before the injector's init
   code runs, that is, before it even had the chance to find the `__environ pointer` and read the process environment.
   This would lead to the injector reporting `OPENSSL_armcap=null` to OpenSSL, even if it is actually set.
   Obviously, this is also not acceptable, hence exporting `getenv` is not a viable approach.

In the end, avoiding the risk of breaking assumptions about the environment is deemed much more critical than not adding
irrelevant environment variables to the environment of all processes, which is effectively more an aesthetics concern.
If an executable does not read `NODE_OPTIONS` (because it is not Node.js), or `JAVA_TOOL_OPTIONS` (because it is not a
JVM), it effectively makes no difference that these variables are added.

## Dynamically Linked libc-free Binaries

Several of the sections above make reference to binaries that are dynamically linked, but do not link against any libc,
and how that is problematic for an `LD_PRELOAD`-based injector, especially when it declares a dependency on any symbol
that is usually provided by libc, like `setenv`, `getenv` or `__environ`.

But does something like this actually exist out in the wild?  Yes, it does.

One example is the `aws-vpc-cni` binary (and probably other related `aws-` binaries that are built in the same way),
from the suite of CNI network plug-ins, which runs in Kubernetes pods in the `kube-system` namespace in EKS clusters.
Here is how this binary is
[built](https://github.com/aws/amazon-vpc-cni-k8s/blob/4ee9789484258d1ae8f6bf36859ea325097d5d7b/Makefile#L149-L152):
It is written in Go and built with `-buildmode=pie` and `-ldflags '-s -w'`.
There is also a [trivial test application](injector-integration-tests/runtimes/no-environ-symbol) that is built in the
same way, contained in this repository.

When using an `LD_PRELOAD`-based injector that declares a dependency on `__environ` (or any other libc symbol), a binary
built in this way will crash at startup with an error message like this:

```
/app/aws-vpc-cni: symbol lookup error: /path/to/libotelinject.so: undefined symbol: __environ
```

This is because the binary is dynamically linked, hence it is affected by `LD_PRELOAD`, but it does not link against
any libc, hence the `__environ` symbol cannot be resolved.
This was a known issue in a previous version of the injector, the current implementation has solved this problem by
not declaring any direct dependencies on external symbols.
