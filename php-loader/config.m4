dnl Copyright The OpenTelemetry Authors
dnl SPDX-License-Identifier: Apache-2.0

PHP_ARG_ENABLE([otel_loader],
  [whether to enable the OpenTelemetry PHP universal loader],
  [AS_HELP_STRING([--enable-otel-loader],
    [Enable the OpenTelemetry PHP universal loader])],
  [no])

if test "$PHP_OTEL_LOADER" != "no"; then
  dnl dladdr() is how the loader recovers its own install path, and with it the
  dnl libc flavor the injector selected. It needs -ldl on glibc and is part of
  dnl libc proper on musl, where PHP_ADD_LIBRARY is harmless.
  PHP_ADD_LIBRARY(dl, 1, OTEL_LOADER_SHARED_LIBADD)
  PHP_SUBST(OTEL_LOADER_SHARED_LIBADD)

  PHP_NEW_EXTENSION(otel_loader, otel_loader.c, $ext_shared, , -Wall -Wextra)
fi
