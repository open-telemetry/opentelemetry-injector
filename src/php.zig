// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const config = @import("config.zig");
const print = @import("print.zig");
const types = @import("types.zig");
const test_util = @import("test_util.zig");

const testing = std.testing;

pub const php_ini_scan_dir_env_var_name = "PHP_INI_SCAN_DIR";

// Packaging contract: within the libc-specific directory (e.g. <prefix>/glibc) the package must provide an
// ini file at this relative path, whose only directive is a `zend_extension=` pointing at the universal
// loader next to it. PHP_INI_SCAN_DIR is pointed at the containing directory, not at the file, because PHP
// scans directories rather than accepting individual files.
//
// PHP_INI_SCAN_DIR is the only lever available here: unlike PYTHONPATH or RUBYOPT there is no environment
// variable that makes PHP load code directly, and an ini file is the only thing the engine will accept from
// a directory. Nothing executable can live in that directory -- PHP scans it for `*.ini` only.
const loader_ini_relative_path = "otel-loader.ini";

var libc_info: ?types.LibCInfo = null;

pub fn setLibcInfo(info: types.LibCInfo) void {
    libc_info = info;
}

/// Returns the modified value for PHP_INI_SCAN_DIR with the directory holding the OpenTelemetry loader ini
/// appended to the original value (if any). Returns null if PHP auto-instrumentation is disabled,
/// unconfigured, the libc flavor is unknown, the loader ini cannot be accessed, or the directory is already
/// present in the original value.
///
/// Unlike the other runtimes, no attempt is made to detect whether this process is actually PHP. Only PHP
/// reads PHP_INI_SCAN_DIR, and the loader the ini points at is built to be loaded by any PHP and to stand
/// down on its own if it cannot support the host -- so the variable is set speculatively, as is already the
/// case for JAVA_TOOL_OPTIONS. This is what makes mod_php work: under Apache, the injector's constructor
/// runs before httpd dlopens libphp.so, so in-process detection could never see PHP at all.
///
/// The caller is responsible for freeing the returned string (unless the result is passed on to setenv and
/// needs to stay in memory).
pub fn checkPhpAutoInstrumentationAgentAndGetModifiedPhpIniScanDirValue(
    io: std.Io,
    gpa: std.mem.Allocator,
    original_value_optional: ?[:0]const u8,
    configuration: config.InjectorConfiguration,
) ?[:0]u8 {
    return doCheckPhpAutoInstrumentationAgentAndGetModifiedPhpIniScanDirValue(
        io,
        gpa,
        original_value_optional,
        configuration.php_auto_instrumentation_agent_path_prefix,
        configuration.php_instrumentation_disabled,
    );
}

fn doCheckPhpAutoInstrumentationAgentAndGetModifiedPhpIniScanDirValue(
    io: std.Io,
    gpa: std.mem.Allocator,
    original_value_optional: ?[:0]const u8,
    php_auto_instrumentation_agent_path_prefix: []u8,
    php_instrumentation_disabled: bool,
) ?[:0]u8 {
    const loader_dir = determineLibcDir(gpa, php_auto_instrumentation_agent_path_prefix, php_instrumentation_disabled) orelse return null;

    const loader_ini = std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ loader_dir, loader_ini_relative_path }, 0) catch |err| {
        print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ php_ini_scan_dir_env_var_name, err });
        gpa.free(loader_dir);
        return null;
    };
    defer gpa.free(loader_ini);

    // Check the ini file itself rather than only the directory. Pointing PHP_INI_SCAN_DIR at a directory
    // that exists but holds no ini would replace the compiled-in scan directory with one that contributes
    // nothing, which silently costs the application its distro conf.d while gaining no instrumentation.
    std.Io.Dir.cwd().access(io, loader_ini, .{}) catch |err| {
        print.printError("Skipping the injection of the PHP OpenTelemetry auto-instrumentation in \"{s}\" because of an issue accessing the loader configuration at \"{s}\": {}", .{ php_ini_scan_dir_env_var_name, loader_ini, err });
        gpa.free(loader_dir);
        return null;
    };

    return getModifiedPhpIniScanDirValue(gpa, original_value_optional, loader_dir);
}

/// Resolves <prefix>/<libc flavor> and returns it, or null if disabled, unconfigured, the prefix contains a
/// colon, or the libc flavor is unknown.
fn determineLibcDir(
    gpa: std.mem.Allocator,
    php_auto_instrumentation_agent_path_prefix: []u8,
    php_instrumentation_disabled: bool,
) ?[:0]u8 {
    if (php_instrumentation_disabled) {
        print.printInfo("Skipping the injection of the PHP OpenTelemetry auto-instrumentation because it has been explicitly disabled.", .{});
        return null;
    }
    if (php_auto_instrumentation_agent_path_prefix.len == 0) {
        // The default state on hosts that have the injector but no php.conf drop-in. This runs for every
        // process on the host, so keep the log at debug to avoid flooding operator logs with an intentional
        // no-op.
        print.printDebug("Skipping the injection of the PHP OpenTelemetry auto-instrumentation because it has not been configured (no path prefix set).", .{});
        return null;
    }

    // PHP_INI_SCAN_DIR is a colon-separated list, so a prefix containing a colon would not merely fail to
    // resolve -- it would split into two directory entries, one of which is attacker-influenced if the
    // prefix comes from an environment variable. Whitespace, unlike in RUBYOPT, is harmless here and is
    // deliberately allowed: PHP does not tokenize this value on whitespace.
    if (std.mem.indexOfScalar(u8, php_auto_instrumentation_agent_path_prefix, ':') != null) {
        print.printError("Skipping the injection of the PHP OpenTelemetry auto-instrumentation because the configured path prefix \"{s}\" contains a colon, which is the separator character of \"{s}\".", .{ php_auto_instrumentation_agent_path_prefix, php_ini_scan_dir_env_var_name });
        return null;
    }

    if (libc_info == null) {
        print.printError("invariant violated: libc info has not been set prior to calling determineLibcDir().", .{});
        return null;
    }

    // Fail-safe on any libc flavor we don't have a directory suffix for. This covers .UNKNOWN today, and
    // any variant added to LibCFlavor in the future -- an `else => unreachable` here would panic in every
    // process's .init_array on hosts running a newly-supported libc before php.zig learns about it.
    const libc_flavor_suffix = switch (libc_info.?.flavor) {
        .GNU => "glibc",
        .MUSL => "musl",
        else => {
            print.printError("Cannot determine libc flavor for PHP auto-instrumentation: \"{s}\"", .{@tagName(libc_info.?.flavor)});
            return null;
        },
    };

    return std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{
        php_auto_instrumentation_agent_path_prefix, libc_flavor_suffix,
    }, 0) catch |err| {
        print.printError("Cannot allocate memory to manipulate the value of \"{s}\" for libc flavor \"{s}\": {}", .{
            php_ini_scan_dir_env_var_name, libc_flavor_suffix, err,
        });
        return null;
    };
}

/// Composes the new PHP_INI_SCAN_DIR value. Takes ownership of `loader_dir`.
///
/// Setting PHP_INI_SCAN_DIR *replaces* the scan directory compiled into PHP, so assigning our directory
/// alone would drop the distribution's conf.d and with it every extension the application depends on. PHP
/// resolves an *empty* entry in the colon-separated list to the compiled-in default, which is the documented
/// way to keep it; this was verified to behave identically on PHP 8.1 through 8.5 by
/// php-loader/probe-ini-scan-dir.sh.
///
/// Our directory goes last so that a distribution ini can never be shadowed by ours.
fn getModifiedPhpIniScanDirValue(
    gpa: std.mem.Allocator,
    original_value_optional: ?[:0]const u8,
    loader_dir: [:0]u8,
) ?[:0]u8 {
    if (original_value_optional) |original_value| {
        if (original_value.len > 0) {
            if (scanDirListContains(original_value, loader_dir)) {
                // Already present, do nothing. This avoids double injection, e.g. when we inject into a
                // shell entry point that then starts the PHP process, which inherits the modified env.
                gpa.free(loader_dir);
                return null;
            }

            defer gpa.free(loader_dir);
            return std.fmt.allocPrintSentinel(gpa, "{s}:{s}", .{ original_value, loader_dir }, 0) catch |err| {
                print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ php_ini_scan_dir_env_var_name, err });
                return null;
            };
        }
    }

    // PHP_INI_SCAN_DIR is unset (or set to the empty string, which means the same thing). The leading colon
    // creates the empty entry that stands for the compiled-in scan directory; without it the application
    // would lose its distro conf.d.
    defer gpa.free(loader_dir);
    return std.fmt.allocPrintSentinel(gpa, ":{s}", .{loader_dir}, 0) catch |err| {
        print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ php_ini_scan_dir_env_var_name, err });
        return null;
    };
}

/// Returns true when `scan_dir_value` already contains `loader_dir` as one of its colon-separated entries.
/// Entry-wise comparison rather than a substring search: a coincidental `/usr/lib/opentelemetry/php/glibc-old`
/// entry would make a substring check falsely suppress injection.
fn scanDirListContains(scan_dir_value: []const u8, loader_dir: []const u8) bool {
    var entries = std.mem.splitScalar(u8, scan_dir_value, ':');
    while (entries.next()) |entry| {
        if (std.mem.eql(u8, entry, loader_dir)) return true;
    }
    return false;
}

test "doCheck...: should return null if PHP instrumentation is disabled" {
    const allocator = testing.allocator;
    _resetState();
    defer _resetState();

    libc_info = test_util.testLibcInfo(.GNU);
    const path_prefix: []u8 = try std.fmt.allocPrint(allocator, "/some/path", .{});
    defer allocator.free(path_prefix);

    const result = doCheckPhpAutoInstrumentationAgentAndGetModifiedPhpIniScanDirValue(
        testing.io,
        allocator,
        null,
        path_prefix,
        true,
    );
    try test_util.expectWithMessage(result == null, "result == null");
}

test "doCheck...: should return null if no path prefix has been configured" {
    const allocator = testing.allocator;
    _resetState();
    defer _resetState();

    libc_info = test_util.testLibcInfo(.GNU);
    const path_prefix: []u8 = try std.fmt.allocPrint(allocator, "", .{});
    defer allocator.free(path_prefix);

    const result = doCheckPhpAutoInstrumentationAgentAndGetModifiedPhpIniScanDirValue(
        testing.io,
        allocator,
        null,
        path_prefix,
        false,
    );
    try test_util.expectWithMessage(result == null, "result == null");
}

test "doCheck...: should return null if the libc flavor has not been set" {
    const allocator = testing.allocator;
    _resetState();
    defer _resetState();

    const path_prefix: []u8 = try std.fmt.allocPrint(allocator, "/some/path", .{});
    defer allocator.free(path_prefix);

    const result = doCheckPhpAutoInstrumentationAgentAndGetModifiedPhpIniScanDirValue(
        testing.io,
        allocator,
        null,
        path_prefix,
        false,
    );
    try test_util.expectWithMessage(result == null, "result == null");
}

test "doCheck...: should return null for an unknown libc flavor" {
    const allocator = testing.allocator;
    _resetState();
    defer _resetState();

    libc_info = test_util.testLibcInfo(.UNKNOWN);
    const path_prefix: []u8 = try std.fmt.allocPrint(allocator, "/some/path", .{});
    defer allocator.free(path_prefix);

    const result = doCheckPhpAutoInstrumentationAgentAndGetModifiedPhpIniScanDirValue(
        testing.io,
        allocator,
        null,
        path_prefix,
        false,
    );
    try test_util.expectWithMessage(result == null, "result == null");
}

test "doCheck...: should return null if the path prefix contains a colon" {
    const allocator = testing.allocator;
    _resetState();
    defer _resetState();

    libc_info = test_util.testLibcInfo(.GNU);
    const path_prefix: []u8 = try std.fmt.allocPrint(allocator, "/some:/path", .{});
    defer allocator.free(path_prefix);

    const result = doCheckPhpAutoInstrumentationAgentAndGetModifiedPhpIniScanDirValue(
        testing.io,
        allocator,
        null,
        path_prefix,
        false,
    );
    try test_util.expectWithMessage(result == null, "result == null");
}

test "doCheck...: should return null if the loader ini does not exist" {
    const allocator = testing.allocator;
    _resetState();
    defer _resetState();

    libc_info = test_util.testLibcInfo(.GNU);
    const path_prefix: []u8 = try std.fmt.allocPrint(allocator, "/invalid/path", .{});
    defer allocator.free(path_prefix);

    const result = doCheckPhpAutoInstrumentationAgentAndGetModifiedPhpIniScanDirValue(
        testing.io,
        allocator,
        null,
        path_prefix,
        false,
    );
    try test_util.expectWithMessage(result == null, "result == null");
}

/// Creates <tmp>/<libc flavor>/otel-loader.ini so the access() gate passes, and returns the absolute path
/// prefix (that is, the parent of the libc-specific directory). The caller owns the returned slice.
fn createLoaderIni(
    allocator: std.mem.Allocator,
    tmp: *testing.TmpDir,
    comptime libc_flavor_suffix: []const u8,
) ![:0]u8 {
    try tmp.dir.createDir(testing.io, libc_flavor_suffix, .default_dir);
    (try tmp.dir.createFile(testing.io, libc_flavor_suffix ++ "/" ++ loader_ini_relative_path, .{})).close(testing.io);
    return try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
}

test "doCheck...: should prepend an empty entry when PHP_INI_SCAN_DIR is not set" {
    const allocator = testing.allocator;
    _resetState();
    defer _resetState();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    libc_info = test_util.testLibcInfo(.GNU);
    const path_prefix = try createLoaderIni(allocator, &tmp, "glibc");
    defer allocator.free(path_prefix);

    const result = doCheckPhpAutoInstrumentationAgentAndGetModifiedPhpIniScanDirValue(
        testing.io,
        allocator,
        null,
        path_prefix,
        false,
    );
    defer if (result) |r| allocator.free(r);

    const expected = try std.fmt.allocPrint(allocator, ":{s}/glibc", .{path_prefix});
    defer allocator.free(expected);
    // The leading colon is what preserves the compiled-in scan directory; without it the application loses
    // its distro conf.d.
    try testing.expectEqualStrings(expected, result orelse "-");
}

test "doCheck...: should append to an existing PHP_INI_SCAN_DIR value" {
    const allocator = testing.allocator;
    _resetState();
    defer _resetState();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    libc_info = test_util.testLibcInfo(.MUSL);
    const path_prefix = try createLoaderIni(allocator, &tmp, "musl");
    defer allocator.free(path_prefix);

    const result = doCheckPhpAutoInstrumentationAgentAndGetModifiedPhpIniScanDirValue(
        testing.io,
        allocator,
        "/etc/php/conf.d",
        path_prefix,
        false,
    );
    defer if (result) |r| allocator.free(r);

    const expected = try std.fmt.allocPrint(allocator, "/etc/php/conf.d:{s}/musl", .{path_prefix});
    defer allocator.free(expected);
    try testing.expectEqualStrings(expected, result orelse "-");
}

test "doCheck...: should treat an empty PHP_INI_SCAN_DIR like an unset one" {
    const allocator = testing.allocator;
    _resetState();
    defer _resetState();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    libc_info = test_util.testLibcInfo(.GNU);
    const path_prefix = try createLoaderIni(allocator, &tmp, "glibc");
    defer allocator.free(path_prefix);

    const result = doCheckPhpAutoInstrumentationAgentAndGetModifiedPhpIniScanDirValue(
        testing.io,
        allocator,
        "",
        path_prefix,
        false,
    );
    defer if (result) |r| allocator.free(r);

    const expected = try std.fmt.allocPrint(allocator, ":{s}/glibc", .{path_prefix});
    defer allocator.free(expected);
    try testing.expectEqualStrings(expected, result orelse "-");
}

test "doCheck...: should not inject twice if the directory is already present" {
    const allocator = testing.allocator;
    _resetState();
    defer _resetState();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    libc_info = test_util.testLibcInfo(.GNU);
    const path_prefix = try createLoaderIni(allocator, &tmp, "glibc");
    defer allocator.free(path_prefix);

    const already_set = try std.fmt.allocPrintSentinel(allocator, ":{s}/glibc", .{path_prefix}, 0);
    defer allocator.free(already_set);

    const result = doCheckPhpAutoInstrumentationAgentAndGetModifiedPhpIniScanDirValue(
        testing.io,
        allocator,
        already_set,
        path_prefix,
        false,
    );
    try test_util.expectWithMessage(result == null, "result == null");
}

test "doCheck...: should still inject when an entry merely shares our prefix" {
    const allocator = testing.allocator;
    _resetState();
    defer _resetState();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    libc_info = test_util.testLibcInfo(.GNU);
    const path_prefix = try createLoaderIni(allocator, &tmp, "glibc");
    defer allocator.free(path_prefix);

    // A substring check would see our directory inside this entry and wrongly skip the injection.
    const already_set = try std.fmt.allocPrintSentinel(allocator, "{s}/glibc-old", .{path_prefix}, 0);
    defer allocator.free(already_set);

    const result = doCheckPhpAutoInstrumentationAgentAndGetModifiedPhpIniScanDirValue(
        testing.io,
        allocator,
        already_set,
        path_prefix,
        false,
    );
    defer if (result) |r| allocator.free(r);

    const expected = try std.fmt.allocPrint(allocator, "{s}/glibc-old:{s}/glibc", .{ path_prefix, path_prefix });
    defer allocator.free(expected);
    try testing.expectEqualStrings(expected, result orelse "-");
}

test "scanDirListContains" {
    try test_util.expectWithMessage(scanDirListContains("/a:/b:/c", "/b"), "finds a middle entry");
    try test_util.expectWithMessage(scanDirListContains(":/b", "/b"), "finds an entry after the empty one");
    try test_util.expectWithMessage(scanDirListContains("/b", "/b"), "finds a sole entry");
    try test_util.expectWithMessage(!scanDirListContains("/bb", "/b"), "does not match a longer entry");
    try test_util.expectWithMessage(!scanDirListContains("/a:/bb", "/b"), "does not substring-match");
    try test_util.expectWithMessage(!scanDirListContains("", "/b"), "does not match in an empty value");
}

/// Only used for unit tests.
fn _resetState() void {
    libc_info = null;
}
