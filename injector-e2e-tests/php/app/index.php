<?php
// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

/*
 * Deliberately contains no OpenTelemetry code at all. Everything the collector receives is
 * produced by opentelemetry-php-distro, which the injector activated without this image knowing
 * anything about it -- that is the property under test.
 *
 * The distro vendors a PHP-Scoper-prefixed copy of the SDK, so classes like
 * \OpenTelemetry\API\Globals are intentionally NOT visible here: an application's own
 * Composer-installed OpenTelemetry cannot collide with the one the distro carries. That is why
 * this fixture asserts on what reaches the collector rather than on SDK state in-process.
 */

$work = 0;
for ($i = 0; $i < 1000; $i++) {
    $work += $i;
}

if (PHP_SAPI !== 'cli') {
    header('Content-Type: text/plain');
}

echo 'SAPI=' . PHP_SAPI . "\n";
// The application's own auto_prepend_file must survive instrumentation.
echo 'OWN_PREPEND=' . (defined('APP_OWN_PREPEND_RAN') ? 'ran' : 'LOST') . "\n";
echo 'AUTO_PREPEND_INI=' . (ini_get('auto_prepend_file') ?: '<unset>') . "\n";
echo 'EXT_LOADED=' . (extension_loaded('opentelemetry_distro') ? 'yes' : 'no') . "\n";
// The hook API the distro's extension exposes; auto-instrumentation packages build on it.
echo 'HOOK_API=' . (function_exists('OpenTelemetry\Instrumentation\hook') ? 'available' : 'MISSING') . "\n";
echo 'SDK_SCOPED=' . (class_exists('\OpenTelemetry\API\Globals') ? 'no' : 'yes') . "\n";
echo 'OPCACHE=' . (ini_get('opcache.enable') ? 'on' : 'off') . "\n";
echo "WORK=$work\n";
echo "APP_RAN\n";
