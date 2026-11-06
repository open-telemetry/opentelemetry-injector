<?php
// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

$command = $argv[1] ?? '';

switch ($command) {
    case 'php-ini-scan-dir':
        echo 'PHP_INI_SCAN_DIR: ' . (getenv('PHP_INI_SCAN_DIR') ?: '<unset>') . "\n";
        break;

    case 'verify-loader-ini-has-been-scanned':
        // Proves PHP actually scanned the directory the injector pointed it at, which is a
        // stronger statement than the environment variable merely having been set.
        echo 'loader ini scanned: ' .
            (ini_get('user_agent') === 'otel-injector-php-no-op-loader' ? 'true' : 'false') . "\n";
        break;

    case 'verify-compiled-in-scan-dir-is-preserved':
        // Setting PHP_INI_SCAN_DIR replaces the compiled-in scan directory. The injector composes
        // an empty leading entry precisely so the distribution's conf.d survives; without it the
        // application silently loses every extension the distribution configured.
        $scanned = php_ini_scanned_files() ?: '';
        echo 'distro conf.d scanned: ' .
            (str_contains($scanned, '/usr/local/etc/php/conf.d/') ? 'true' : 'false') . "\n";
        break;

    case 'custom-env-var':
        $name = $argv[2] ?? '';
        echo $name . ': ' . (getenv($name) ?: '<unset>') . "\n";
        break;

    default:
        fwrite(STDERR, "unknown command: {$command}\n");
        exit(1);
}
