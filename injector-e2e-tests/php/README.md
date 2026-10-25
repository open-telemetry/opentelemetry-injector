# PHP end-to-end tests

Exercises the complete chain against real PHP applications, one per SAPI:

```
injector (.init_array) -> PHP_INI_SCAN_DIR -> otel-loader.ini -> universal loader
                       -> opentelemetry.so -> SDK bootstrap (RINIT) -> an exported span
```

Each case asserts three things at once, because any one of them passing alone would be
misleading:

1. the application ran;
2. a span was actually exported, so instrumentation works end to end rather than merely loading;
3. the application's **own** `auto_prepend_file` still ran — the contract the loader exists to
   keep.

| SAPI | Base image | Shape |
|---|---|---|
| `cli` | `php:8.3-cli` | `php index.php` |
| `builtin` | `php:8.3-cli` | `php -S`, driven with curl |
| `fpm` | `php:8.3-fpm` | php-fpm behind nginx, driven with curl |
| `apache` | `php:8.3-apache` | mod_php, driven with curl |

`apache` is the case the injector's in-process detection could never support: our constructor
runs before `httpd` loads `libphp.so`. It works here because `PHP_INI_SCAN_DIR` is set
speculatively and the loader decides for itself whether it can support the host.

## Running

```bash
make dist ARCH=<arch>          # the injector
make php-loader ARCH=<arch>    # the loader
./prepare-artifacts.sh         # an artifact tree for this architecture
./run.sh [cli|builtin|fpm|apache ...]
```

## Why artifacts are built locally

`ghcr.io/opentelemetry-php/autoinstrumentation-php` is the intended source and its directory
layout is used verbatim. Its **arm64 image currently contains x86-64 binaries**, though, so on
arm64 the tree has to be built locally. `Dockerfile.artifacts` produces the identical layout —
`pecl install opentelemetry` plus a Composer install of the SDK, flattened so that `autoload.php`
and `opentelemetry.so` sit at the root of the variant directory.
