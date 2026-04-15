// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const builtin = @import("builtin");
const std = @import("std");

const proc_self_environ_values = @import("proc_self_environ_values.zig");
const print = @import("print.zig");
const types = @import("types.zig");

const testing = std.testing;

const proc_self_environ_path = "/proc/self/environ";
const otel_injector_log_level_env_var_name = "OTEL_INJECTOR_LOG_LEVEL";
pub const otel_injector_disabled_env_var_name = "OTEL_INJECTOR_DISABLED";

const max_getenv_entry_length = 8192;
const max_getenv_buffer_len = max_getenv_entry_length * 2;

/// Function type for reading environment variables, abstracting over reading from
/// /proc/self/environ (production) vs std.posix.getenv (tests).
pub const GetenvFn = *const fn (allocator: std.mem.Allocator, name: []const u8) ?[]u8;

/// Looks up an environment variable by reading /proc/self/environ directly,
/// without depending on libc or std.posix.getenv.
/// Returns an allocated copy of the value, or null if not found or on error.
/// Errors are treated the same as a missing variable: if /proc/self/environ is
/// unreadable, callers that rely on this function (e.g. for OTEL_INJECTOR_CONFIG_FILE)
/// will silently fall back to their defaults. This is intentional — initFromProcSelfEnviron
/// runs earlier and will have already surfaced any read failure at a higher log level.
/// The caller is responsible for freeing the returned slice.
pub fn getenv(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    return getenvFromFile(allocator, proc_self_environ_path, name) catch null;
}

/// Wraps std.posix.getenv with the GetenvFn signature for use in tests,
/// where environment variables are set via setenv()/putenv() rather than
/// being present in /proc/self/environ.
pub fn posixGetenv(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    const val = std.posix.getenv(name) orelse return null;
    return allocator.dupe(u8, val) catch unreachable;
}

fn getenvFromFile(allocator: std.mem.Allocator, path: []const u8, name: []const u8) !?[]u8 {
    var environ_file = try std.fs.openFileAbsolute(path, .{});
    defer environ_file.close();
    var buf: [max_getenv_buffer_len]u8 = undefined;
    var reader = environ_file.reader(&buf);
    while (takeSentinelOrDiscardOverlyLongLine(&reader)) |environ_entry| {
        if (matchEntry(environ_entry, name)) |value| {
            return try allocator.dupe(u8, value);
        }
    } else |err| switch (err) {
        error.EndOfStream => {
            var last_buf: [max_getenv_entry_length]u8 = undefined;
            const chars = reader.interface.readSliceShort(&last_buf) catch return null;
            if (matchEntry(last_buf[0..chars], name)) |value| {
                return try allocator.dupe(u8, value);
            }
        },
        else => return err,
    }
    return null;
}

fn matchEntry(entry: []const u8, name: []const u8) ?[]const u8 {
    if (entry.len <= name.len) return null;
    if (!std.mem.startsWith(u8, entry, name)) return null;
    if (entry[name.len] != '=') return null;
    return entry[name.len + 1 ..];
}

/// Initializes a few selected configuration settings (injector disabled, log level) based on environment variables
/// (OTEL_INJECTOR_DISABLED, OTEL_INJECTOR_LOG_LEVEL), by reading /proc/self/environ directly. This runs before
/// libc detection, config file reading, and allow/deny filtering — all of which depend on these settings or must
/// complete before libc is accessed. The __environ pointer from libc is not yet available at this stage.
pub fn initFromProcSelfEnviron() !void {
    try initFromEnvironFile(proc_self_environ_path);
}

fn initFromEnvironFile(self_environ_path: []const u8) !void {
    proc_self_environ_values.setPid(switch (builtin.target.os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        // Note: the injector does not support any OS besides Linux, this case is only here to support running Zig unit
        // tests directly on Darwin.
        .macos => @intCast(std.c.getpid()),
        else => {
            error.OsNotSupported;
        },
    });

    const allocator = std.heap.page_allocator;

    const log_level_value = getenvFromFile(allocator, self_environ_path, otel_injector_log_level_env_var_name) catch |err| switch (err) {
        error.ReadFailed => {
            print.printWarn("Failed to read {s}", .{self_environ_path});
            return;
        },
        else => return err,
    };
    defer if (log_level_value) |v| allocator.free(v);

    const disabled_value = getenvFromFile(allocator, self_environ_path, otel_injector_disabled_env_var_name) catch |err| switch (err) {
        error.ReadFailed => null,
        else => return err,
    };
    defer if (disabled_value) |v| allocator.free(v);

    if (disabled_value) |v| {
        proc_self_environ_values.setOtelInjectorDisabled(parseBooleanValue(v));
    }

    if (log_level_value) |log_level| {
        if (std.ascii.eqlIgnoreCase("debug", log_level)) {
            proc_self_environ_values.setLogLevel(.Debug);
        } else if (std.ascii.eqlIgnoreCase("info", log_level)) {
            proc_self_environ_values.setLogLevel(.Info);
        } else if (std.ascii.eqlIgnoreCase("warn", log_level)) {
            proc_self_environ_values.setLogLevel(.Warn);
        } else if (std.ascii.eqlIgnoreCase("error", log_level)) {
            proc_self_environ_values.setLogLevel(.Error);
        } else if (std.ascii.eqlIgnoreCase("none", log_level)) {
            proc_self_environ_values.setLogLevel(.None);
        } else {
            print.printError("unknown value for OTEL_INJECTOR_LOG_LEVEL: \"{s}\" -- valid log levels are \"debug\", \"info\", \"warn\", \"error\", \"none\".", .{log_level});
        }
    }
    print.printDebug("log level: {}", .{proc_self_environ_values.getLogLevel()});
}

fn takeSentinelOrDiscardOverlyLongLine(reader: *std.fs.File.Reader) ![:0]u8 {
    if (reader.interface.takeSentinel(0)) |slice| {
        return slice;
    } else |err| switch (err) {
        error.StreamTooLong => {
            // Ignore lines that are too long for the buffer; advance the the read positon to the next delimiter to
            // avoid stream corruption.
            _ = try reader.interface.discardDelimiterInclusive(0);
            return @constCast("");
        },
        else => |leftover_err| return leftover_err,
    }
}

test "initFromEnvironFile: empty /proc/self/environ" {
    defer proc_self_environ_values.reset();
    const allocator = testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_environ_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/proc-self-environ/empty" });
    defer allocator.free(absolute_path_to_environ_file);
    try initFromEnvironFile(absolute_path_to_environ_file);
    // verify that the default log level is set
    try testing.expectEqual(.Error, proc_self_environ_values.getLogLevel());
    try testing.expectEqual(false, proc_self_environ_values.getOtelInjectorDisabled());
}

test "initFromEnvironFile: nothing is not set" {
    defer proc_self_environ_values.reset();
    const allocator = testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_environ_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/proc-self-environ/environ-nothing-set" });
    defer allocator.free(absolute_path_to_environ_file);
    try initFromEnvironFile(absolute_path_to_environ_file);
    // verify that the default log level is set
    try testing.expectEqual(.Error, proc_self_environ_values.getLogLevel());
    try testing.expectEqual(false, proc_self_environ_values.getOtelInjectorDisabled());
}

test "initFromEnvironFile: OTEL_INJECTOR_LOG_LEVEL=debug" {
    defer proc_self_environ_values.reset();
    const allocator = testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_environ_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/proc-self-environ/environ-log-level-debug" });
    defer allocator.free(absolute_path_to_environ_file);
    try initFromEnvironFile(absolute_path_to_environ_file);
    try testing.expectEqual(.Debug, proc_self_environ_values.getLogLevel());
}

test "initFromEnvironFile: OTEL_INJECTOR_LOG_LEVEL=info" {
    defer proc_self_environ_values.reset();
    const allocator = testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_environ_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/proc-self-environ/environ-log-level-info" });
    defer allocator.free(absolute_path_to_environ_file);
    try initFromEnvironFile(absolute_path_to_environ_file);
    try testing.expectEqual(.Info, proc_self_environ_values.getLogLevel());
}

test "initFromEnvironFile: OTEL_INJECTOR_LOG_LEVEL=warn" {
    defer proc_self_environ_values.reset();
    const allocator = testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_environ_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/proc-self-environ/environ-log-level-warn" });
    defer allocator.free(absolute_path_to_environ_file);
    try initFromEnvironFile(absolute_path_to_environ_file);
    try testing.expectEqual(.Warn, proc_self_environ_values.getLogLevel());
}

test "initFromEnvironFile: OTEL_INJECTOR_LOG_LEVEL=error" {
    defer proc_self_environ_values.reset();
    const allocator = testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_environ_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/proc-self-environ/environ-log-level-error" });
    defer allocator.free(absolute_path_to_environ_file);
    try initFromEnvironFile(absolute_path_to_environ_file);
    try testing.expectEqual(.Error, proc_self_environ_values.getLogLevel());
}

test "initFromEnvironFile: OTEL_INJECTOR_LOG_LEVEL=none" {
    defer proc_self_environ_values.reset();
    const allocator = testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_environ_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/proc-self-environ/environ-log-level-none" });
    defer allocator.free(absolute_path_to_environ_file);
    try initFromEnvironFile(absolute_path_to_environ_file);
    try testing.expectEqual(.None, proc_self_environ_values.getLogLevel());
}

test "initFromEnvironFile: OTEL_INJECTOR_LOG_LEVEL is an arbitrary string" {
    defer proc_self_environ_values.reset();
    const allocator = testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_environ_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/proc-self-environ/environ-log-level-arbitrary-string" });
    defer allocator.free(absolute_path_to_environ_file);
    try initFromEnvironFile(absolute_path_to_environ_file);
    try testing.expectEqual(.Error, proc_self_environ_values.getLogLevel());
}

test "initFromEnvironFile: OTEL_INJECTOR_DISABLED=true" {
    defer proc_self_environ_values.reset();
    const allocator = testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_environ_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/proc-self-environ/environ-injector-disabled-true" });
    defer allocator.free(absolute_path_to_environ_file);
    try initFromEnvironFile(absolute_path_to_environ_file);
    try testing.expectEqual(true, proc_self_environ_values.getOtelInjectorDisabled());
}

test "initFromEnvironFile: OTEL_INJECTOR_DISABLED=false" {
    defer proc_self_environ_values.reset();
    const allocator = testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_environ_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/proc-self-environ/environ-injector-disabled-false" });
    defer allocator.free(absolute_path_to_environ_file);
    try initFromEnvironFile(absolute_path_to_environ_file);
    try testing.expectEqual(false, proc_self_environ_values.getOtelInjectorDisabled());
}

test "initFromEnvironFile: OTEL_INJECTOR_DISABLED=1" {
    defer proc_self_environ_values.reset();
    const allocator = testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_environ_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/proc-self-environ/environ-injector-disabled-1" });
    defer allocator.free(absolute_path_to_environ_file);
    try initFromEnvironFile(absolute_path_to_environ_file);
    try testing.expectEqual(true, proc_self_environ_values.getOtelInjectorDisabled());
}

test "initFromEnvironFile: OTEL_INJECTOR_DISABLED is an arbitrary string" {
    defer proc_self_environ_values.reset();
    const allocator = testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_environ_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/proc-self-environ/environ-injector-disabled-arbitrary-string" });
    defer allocator.free(absolute_path_to_environ_file);
    try initFromEnvironFile(absolute_path_to_environ_file);
    try testing.expectEqual(false, proc_self_environ_values.getOtelInjectorDisabled());
}

test "initFromEnvironFile: both OTEL_INJECTOR_LOG_LEVEL and OTEL_INJECTOR_DISABLED are set" {
    defer proc_self_environ_values.reset();

    const environ_files = [_][]const u8{
        "unit-test-assets/proc-self-environ/environ-log-level-then-disabled",
        "unit-test-assets/proc-self-environ/environ-disabled-then-log-level",
    };

    for (environ_files) |environ_file| {
        const allocator = testing.allocator;
        const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
        defer allocator.free(cwd_path);
        const absolute_path_to_environ_file = try std.fs.path.resolve(allocator, &.{ cwd_path, environ_file });
        defer allocator.free(absolute_path_to_environ_file);
        try initFromEnvironFile(absolute_path_to_environ_file);
        try testing.expectEqual(true, proc_self_environ_values.getOtelInjectorDisabled());
        try testing.expectEqual(true, proc_self_environ_values.getOtelInjectorDisabled());
        proc_self_environ_values.reset();
    }
}

test "initFromEnvironFile: overly long environment variable" {
    defer proc_self_environ_values.reset();
    const allocator = testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_environ_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/proc-self-environ/overly-long-env-var" });
    defer allocator.free(absolute_path_to_environ_file);
    try initFromEnvironFile(absolute_path_to_environ_file);
    try testing.expectEqual(.None, proc_self_environ_values.getLogLevel());
    try testing.expectEqual(true, proc_self_environ_values.getOtelInjectorDisabled());
}

inline fn parseBooleanValue(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "t") or
        std.mem.eql(u8, value, "1");
}

test "parseBooleanValue: correctly identifies true and false values" {
    const true_values = [_][]const u8{ "true", "True", "TRUE", "t", "T", "1" };
    const false_values = [_][]const u8{ "false", "False", "FALSE", "f", "F", "0", "", "random", "yes", "no", "ON" };

    for (true_values) |value| {
        try testing.expect(parseBooleanValue(value));
    }

    for (false_values) |value| {
        try testing.expect(!parseBooleanValue(value));
    }
}

fn resolveTestAssetPath(allocator: std.mem.Allocator, relative_path: []const u8) ![]u8 {
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    return std.fs.path.resolve(allocator, &.{ cwd_path, relative_path });
}

test "getenvFromFile: variable found at start of file" {
    const allocator = testing.allocator;
    const path = try resolveTestAssetPath(allocator, "unit-test-assets/proc-self-environ/environ-log-level-debug");
    defer allocator.free(path);
    const value = try getenvFromFile(allocator, path, "ENV_VAR_1");
    defer if (value) |v| allocator.free(v);
    try testing.expectEqualStrings("value_1", value.?);
}

test "getenvFromFile: variable found in middle of file" {
    const allocator = testing.allocator;
    const path = try resolveTestAssetPath(allocator, "unit-test-assets/proc-self-environ/environ-log-level-debug");
    defer allocator.free(path);
    const value = try getenvFromFile(allocator, path, "OTEL_INJECTOR_LOG_LEVEL");
    defer if (value) |v| allocator.free(v);
    try testing.expectEqualStrings("debug", value.?);
}

test "getenvFromFile: variable found at end of file" {
    const allocator = testing.allocator;
    const path = try resolveTestAssetPath(allocator, "unit-test-assets/proc-self-environ/environ-log-level-debug");
    defer allocator.free(path);
    const value = try getenvFromFile(allocator, path, "ENV_VAR_2");
    defer if (value) |v| allocator.free(v);
    try testing.expectEqualStrings("value_2", value.?);
}

test "getenvFromFile: variable not found returns null" {
    const allocator = testing.allocator;
    const path = try resolveTestAssetPath(allocator, "unit-test-assets/proc-self-environ/environ-log-level-debug");
    defer allocator.free(path);
    const value = try getenvFromFile(allocator, path, "DOES_NOT_EXIST");
    try testing.expectEqual(null, value);
}

test "getenvFromFile: prefix of variable name does not match" {
    const allocator = testing.allocator;
    const path = try resolveTestAssetPath(allocator, "unit-test-assets/proc-self-environ/environ-log-level-debug");
    defer allocator.free(path);
    // "ENV_VAR" is a prefix of "ENV_VAR_1" and "ENV_VAR_2" but should not match either
    const value = try getenvFromFile(allocator, path, "ENV_VAR");
    try testing.expectEqual(null, value);
}

test "getenvFromFile: overlong entry is skipped, subsequent entries still found" {
    const allocator = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    {
        const f = try tmp_dir.dir.createFile("environ", .{});
        defer f.close();
        // Write an entry strictly longer than max_getenv_entry_length to trigger StreamTooLong
        try f.writeAll("OVERLONG_VAR=");
        const chunk = [_]u8{'x'} ** 64;
        var written: usize = 0;
        while (written <= max_getenv_entry_length) {
            const n = @min(chunk.len, max_getenv_entry_length + 1 - written);
            try f.writeAll(chunk[0..n]);
            written += n;
        }
        try f.writeAll(&[1]u8{0}); // null terminator
        try f.writeAll("TARGET_VAR=found_after_overlong");
        try f.writeAll(&[1]u8{0});
    }
    const path = try tmp_dir.dir.realpathAlloc(allocator, "environ");
    defer allocator.free(path);

    const value = try getenvFromFile(allocator, path, "TARGET_VAR");
    defer if (value) |v| allocator.free(v);
    try testing.expectEqualStrings("found_after_overlong", value.?);
}
