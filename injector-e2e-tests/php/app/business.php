<?php
// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

/**
 * Deliberately in its own file, required only after the hook is registered.
 *
 * opentelemetry.so installs a hook by rewriting the target function's compiled op_array, so the
 * hook has to exist before the function is compiled. Under opcache -- on by default for fpm,
 * apache and the built-in server -- a compiled file lives in immutable shared memory, so a hook
 * registered after compilation silently never fires. Real auto-instrumentation packages avoid
 * this by registering their hooks during the SDK autoload, before any application file is
 * compiled; this fixture reproduces that ordering rather than papering over it by disabling
 * opcache.
 */
function businessOperation(): string
{
    return 'done';
}
