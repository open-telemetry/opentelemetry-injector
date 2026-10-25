# The OpenTelemetry PHP universal loader

A Zend extension that can be loaded by **any** PHP — 8.1 through 8.5, NTS or ZTS, glibc or musl,
debug or release — from a single binary per `{libc, architecture}`. It resolves the
`opentelemetry.so` actually built for the host, activates it, and bootstraps the PHP-level SDK,
without an init container and without `auto_prepend_file`.

It exists to solve two problems that cannot be solved from outside the process:

1. **Version dispatch under every SAPI.** The OpenTelemetry PHP artifacts are built per
   `{module API, libc, thread-safety}`. An injector that sets `PHP_INI_SCAN_DIR` can select the
   right directory itself *only* when PHP is linked into the executable at `exec()` time. Under
   Apache, `mod_php` is `dlopen`ed later, so nothing outside the engine can know which variant
   applies. A loader runs inside the engine, so it always can.
2. **Bootstrapping the SDK without `auto_prepend_file`.** The upstream package's ini uses
   `auto_prepend_file`, which is single-valued and last-ini-wins: enabling instrumentation
   silently removes whatever the application had set there. The loader runs the SDK's Composer
   autoloader from a module's `RINIT` instead, leaving the directive untouched.

Prior art: Datadog's [`dd_library_loader`](https://github.com/DataDog/dd-trace-php/tree/master/loader)
uses the same version-gate escape. It is not prior art for (2): `dd-trace-php`'s tracer core is
C/Rust and has no userland bootstrap. For that part the closest precedent is
`elastic/apm-agent-php`, which likewise executes its PHP bootstrap from the extension.

## How the version gate is escaped

`Zend/zend_extensions.c` is explicit about this being allowed — *"allow extension to proclaim
compatibility with any Zend version"*. If a `zend_extension` supplies `api_no_check` /
`build_id_check` callbacks, the engine calls them **instead of** refusing to load on a mismatch.

The loader declares deliberately impossible version info (`{0, "0"}`) so that the mismatch is
guaranteed and *every* PHP takes the same, tested code path — rather than loading silently on
whichever version it happened to be compiled against and going through the callbacks everywhere
else.

The callbacks are also the only way to learn about the host:

| From | What it yields |
|---|---|
| `api_no_check(int)` | Zend extension API, e.g. `420230831`; `% 100000000` → module API `20230831` |
| `build_id_check(const char *)` | `"API420230831,NTS"` → thread-safety flavor, and whether it is a debug build |

## Install layout

```
<root>/<libc>/otel_loader.so        <- the ini points here; PHP_INI_SCAN_DIR points at <libc>/
<root>/<libc>/otel-loader.ini       <- one line: zend_extension=<abs path to otel_loader.so>
<root>/<module_api>/<libc>/<zts|non-zts>/
        opentelemetry.so
        autoload.php
        <composer vendor tree>
```

The loader recovers `<root>` and `<libc>` from **its own path** via `dladdr()`. The injector
already determined the libc flavor (`src/libc.zig`) and encoded that decision by pointing the ini
at one binary rather than the other, so re-detecting it inside the loader would only create a
second source of truth that can disagree with the first. `OTEL_PHP_AUTOINSTRUMENTATION_ROOT`
overrides the root for tests; the flavor is never overridable.

The `<module_api>/<libc>/<thread>` tree is exactly what
`ghcr.io/opentelemetry-php/autoinstrumentation-php` already publishes, so it drops in unmodified.
The shipped `opentelemetry.ini` is **not** used — that is the one with the `auto_prepend_file`.

## Rules this code lives by

- **Never touch an engine global.** `EG()`, `CG()` and everything built on them — `zend_try`
  included — compile to a direct `executor_globals` reference on NTS and a TSRM offset lookup on
  ZTS. One binary that touches a global loads on exactly half the matrix and fails on the other
  with `undefined symbol: executor_globals`. `Dockerfile.build` fails the build if any such symbol
  is undefined in the output.
- **Re-validate before activating.** The engine's own `zend_api` and `build_id` checks live in
  `ext/standard/dl.c`, on the `extension=` path we are bypassing. If the loader does not repeat
  them, nothing does — and activating an extension built for a different PHP corrupts the engine
  rather than failing cleanly.
- **Use `zend_startup_module()`, not `zend_register_module_ex()`.** The latter gained a second
  parameter in PHP 8.4, so calling it from a single binary serving 8.1–8.5 would corrupt the
  stack. It would also be insufficient: `zend_startup_modules()` has already run by the time a
  `zend_extension` starts, so a merely-registered module never receives its `MINIT`.
- **Fail closed, always.** Every failure path logs and stands down, leaving the application
  running uninstrumented. Any `Unknown` means stand down; never guess.
- **Gate on the number, fail on artifact lookup.** A PHP newer than anything we ship passes every
  version check and then finds no artifact directory. A new PHP release therefore loses
  instrumentation until the *artifacts* catch up, not until the *loader* is rebuilt.

## Building and testing

```bash
./build.sh [glibc|musl|all] [amd64|arm64|all]   # -> dist/php/<libc>/<arch>/otel_loader.so
./test-matrix.sh [arch]                         # 20 cases: 8.1-8.5 x {glibc,musl} x {nts,zts}
./probe-ini-scan-dir.sh                         # PHP_INI_SCAN_DIR semantics, per version
```

The loader is compiled against **PHP 8.1** headers — the oldest supported version, so that every
struct it touches is one all supported versions agree on. `_zend_extension` and
`_zend_module_entry` are byte-identical from 8.1 to 8.5.

## Verified behavior

Measured, not assumed. `test-matrix.sh`, 20/20 on both architectures:

| | 8.1 | 8.2 | 8.3 | 8.4 | 8.5 |
|---|---|---|---|---|---|
| glibc NTS / ZTS | ok | ok | ok | ok | ok |
| musl NTS / ZTS | ok | ok | ok | ok | ok |

Alongside those, confirmed by hand:

- **PHP 7.4** loads the loader, reports module API `20190902`, finds no artifacts and stands down.
  The application is unaffected.
- **An application that sets its own `auto_prepend_file`** keeps it, and its prepend script still
  runs, while the SDK bootstraps and emits spans — the RINIT bootstrap doing its job.
- **A wrong install path** (parent directory not `glibc`/`musl`) stands down rather than guessing.
- **glibc floor is 2.17.** Building on a current base image otherwise stamps a `GLIBC_2.34`
  requirement on the binary — from `dladdr` alone — which silently loses instrumentation on
  RHEL/UBI 8 (2.28) and Debian bullseye (2.31). The `.symver` block in `otel_loader.c` pins the
  backward-compatible symbol versions and the build asserts the floor.

## Known upstream issue

`ghcr.io/opentelemetry-php/autoinstrumentation-php:latest` publishes a multi-architecture manifest
(amd64, arm64, s390x, ppc64le), but the **arm64 image contains x86-64 `opentelemetry.so`
binaries**:

```
$ docker run --rm --platform linux/arm64 --entrypoint sh \
    ghcr.io/opentelemetry-php/autoinstrumentation-php:latest \
    -c 'od -An -tx1 -j18 -N2 /autoinstrumentation/20230831/glibc/non-zts/opentelemetry.so'
 3e 00      # ELF e_machine 0x3e = x86-64, expected 0xb7 = aarch64
```

The loader degrades correctly (`dlopen` fails, it stands down, the application runs), but arm64
hosts get no instrumentation. This needs fixing upstream before the arm64 half of the alpha scope
can be met.
