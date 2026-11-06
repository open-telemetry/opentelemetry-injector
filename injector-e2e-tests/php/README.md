# PHP end-to-end tests

Exercises the complete chain against real PHP applications, one per SAPI:

```
injector (.init_array) -> PHP_INI_SCAN_DIR -> otel-loader.ini
                       -> opentelemetry-php-distro's universal loader
                       -> the extension matching this PHP -> SDK bootstrap -> an exported span
```

The application fixture (`app/index.php`) contains **no OpenTelemetry code at all**. Every span
the collector receives was produced by the distro on its own, which is the property being tested:
a stock image, instrumented without modification.

Each case asserts several things at once, because any one of them passing alone would be
misleading:

1. the application ran;
2. the distro's extension is loaded and its hook API is live;
3. the distro's SDK is **scoped** — `\OpenTelemetry\API\Globals` must *not* be visible to the
   application, so an app's own Composer-installed OpenTelemetry cannot collide with it;
4. a root span reached a real collector over OTLP, from the SAPI under test
   (`process.runtime.name`) and with HTTP semantic attributes on the server SAPIs;
5. the application's **own** `auto_prepend_file` still ran.

| SAPI | Base image | Shape |
|---|---|---|
| `cli` | `php:8.3-cli` | `php index.php` |
| `builtin` | `php:8.3-cli` | `php -S`, driven with curl |
| `fpm` | `php:8.3-fpm` | php-fpm behind nginx, driven with curl |
| `apache` | `php:8.3-apache` | mod_php, driven with curl |

`apache` is the case the injector's in-process detection could never support: our constructor runs
before `httpd` loads `libphp.so`. It works here because `PHP_INI_SCAN_DIR` is set speculatively and
the loader decides for itself whether it can support the host.

## Running

```bash
make dist ARCH=<arch>     # the injector
make php-artifacts        # stage opentelemetry-php-distro into dist/php/<libc>/
./run.sh [cli|builtin|fpm|apache ...]
```

or `make php-e2e-tests ARCH=<arch>`, which does all three.

## Why the distro's post-install script is not used

`prepare-artifacts.sh` unpacks the distro's `.deb` and writes its own ini rather than running the
packaged `post-install.sh`. That script discovers the host PHP with `php -i` and writes
`extension=` lines into every SAPI's `conf.d` — a host-wide mutation of the image, which is
exactly what the injector exists to avoid, and which cannot work when the artifacts arrive on a
mounted volume rather than through a package manager.

The two lines the ini contains are the distro's own documented manual-setup instructions:

```ini
extension=/opt/opentelemetry/php/distro/opentelemetry_php_distro_loader.so
opentelemetry_distro.bootstrap_php_part_file=/opt/opentelemetry/php/distro/php/bootstrap_php_part.php
```

Note that the distro bootstraps its PHP part through that ini setting, not through
`auto_prepend_file`, so an application that uses that directive keeps it.

## Kubernetes

`k8s/` runs the same chain in a kind cluster, with the injector and the distro delivered by an
init container into an `emptyDir` and the injector configured by a ConfigMap — the shape an
operator's mutating webhook produces. See `make php-k8s-poc`.
