<?php
// No OpenTelemetry code whatsoever. The distro produces the server span by itself.
$work = 0;
for ($i = 0; $i < 1000; $i++) {
    $work += $i;
}
header('Content-Type: text/plain');
echo "php-injector-poc ok\n";
echo 'sapi=' . PHP_SAPI . "\n";
echo 'distro_ext=' . (extension_loaded('opentelemetry_distro') ? 'loaded' : 'absent') . "\n";
echo "work=$work\n";
