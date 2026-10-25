<?php
// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

/*
 * The span for businessOperation() is produced by opentelemetry.so's hook API -- the same
 * mechanism every auto-instrumentation package uses -- so a span named "auto-hooked-span"
 * arriving at the collector proves the extension the loader dispatched is functional, not merely
 * loaded. An extension that loaded but did not work would still satisfy extension_loaded().
 *
 * The hook is registered before business.php is required, because the hook must exist before the
 * target function is compiled. See business.php.
 */
$GLOBALS['otel_e2e_hook_fired'] = false;
$hookRegistered = \OpenTelemetry\Instrumentation\hook(
    null,
    'businessOperation',
    pre: static function (): void {
        $GLOBALS['otel_e2e_hook_fired'] = true;
        $tracer = \OpenTelemetry\API\Globals::tracerProvider()->getTracer('e2e-auto');
        $span = $tracer->spanBuilder('auto-hooked-span')->startSpan();
        $GLOBALS['otel_e2e_hook_span'] = $span;
    },
    post: static function (): void {
        if (isset($GLOBALS['otel_e2e_hook_span'])) {
            $GLOBALS['otel_e2e_hook_span']->end();
        }
    },
);

// A manually created span, through the globally registered provider. This only works if the
// autoload actually configured the SDK, rather than merely putting its classes on disk.
$tracer = \OpenTelemetry\API\Globals::tracerProvider()->getTracer('e2e');
$span = $tracer->spanBuilder('e2e-span')->startSpan();
$span->setAttribute('sapi', PHP_SAPI);
$span->end();

require __DIR__ . '/business.php';
businessOperation();

// Force the export to complete before the process or request ends, so the assertions do not
// race the batch processor. The API-level provider interface has no forceFlush(); only a
// configured SDK provider does, which makes its absence a precise signal that the autoload did
// not configure the SDK rather than a fatal error at the end of the script.
$provider = \OpenTelemetry\API\Globals::tracerProvider();
$configured = method_exists($provider, 'forceFlush');
if ($configured) {
    $provider->forceFlush();
}

echo "SDK_CONFIGURED=" . ($configured ? 'yes' : 'NO') . "\n";
echo "SAPI=" . PHP_SAPI . "\n";
echo "OWN_PREPEND=" . (defined('APP_OWN_PREPEND_RAN') ? 'ran' : 'LOST') . "\n";
echo "AUTO_PREPEND_INI=" . (ini_get('auto_prepend_file') ?: '<unset>') . "\n";
echo "EXT_LOADED=" . (extension_loaded('opentelemetry') ? 'yes' : 'no') . "\n";
echo "HOOK_REGISTERED=" . (($hookRegistered ?? false) ? 'yes' : 'NO') . "\n";
echo "HOOK_FIRED=" . ($GLOBALS['otel_e2e_hook_fired'] ? 'yes' : 'NO') . "\n";
echo "OPCACHE=" . (ini_get('opcache.enable') ? 'on' : 'off') . "/" . (ini_get('opcache.enable_cli') ? 'cli-on' : 'cli-off') . "\n";
echo "HOOK_API=" . (function_exists('OpenTelemetry\Instrumentation\hook') ? 'available' : 'MISSING') . "\n";
echo "APP_RAN\n";
