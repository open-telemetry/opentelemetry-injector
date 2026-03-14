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
const otel_injector_log_level_environ_prefix = "OTEL_INJECTOR_LOG_LEVEL=";
pub const otel_injector_disabled_env_var_name = "OTEL_INJECTOR_DISABLED";
const otel_injector_disabled_env_var_prefix = "OTEL_INJECTOR_DISABLED=";

/// Initializes a few selected configuration settings (injector disabled, log level) based on environment variables
/// (OTEL_INJECTOR_DISABLED, OTEL_INJECTOR_LOG_LEVEL), by reading /proc/self/environ line by line. When reading
/// environment variables later in the injector's life cycle, we will use the pointer to the __environ array after
/// looking it up via libc.getLibCInfo(), but this pointer is not available during the injector's initialization phase
/// yet, and we need to know some settings _before_ running libc.getLibCInfo().
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

    var log_level_env_var_value: ?[]const u8 = null;

    var environ_file = try std.fs.openFileAbsolute(self_environ_path, .{});
    defer environ_file.close();
    const max_line_length = 256;
    const max_buffer_len = max_line_length * 2;
    var buf: [max_buffer_len]u8 = undefined;
    var reader = environ_file.reader(&buf);
    while (takeSentinelOrDiscardOverlyLongLine(&reader)) |environ_entry| {
        if (environ_entry.len > max_line_length) {
            continue;
        }
        if (std.mem.startsWith(u8, environ_entry, otel_injector_log_level_environ_prefix)) {
            log_level_env_var_value = environ_entry[otel_injector_log_level_environ_prefix.len..environ_entry.len];
            continue;
        }
        if (std.mem.startsWith(u8, environ_entry, otel_injector_disabled_env_var_prefix)) {
            const otel_injector_disabled_env_var_value =
                environ_entry[otel_injector_disabled_env_var_prefix.len..environ_entry.len];
            proc_self_environ_values.setOtelInjectorDisabled(parseBooleanValue(otel_injector_disabled_env_var_value));
            continue;
        }
    } else |err| switch (err) {
        error.ReadFailed => {
            print.printWarn("Failed to read {s}", .{self_environ_path});
            return;
        },
        // if the file does not end with a 0 byte, we still need to parse the last entry
        // (realistically this probably will not occur for /proc/self/environ)
        error.EndOfStream => {
            var buffer: [max_line_length]u8 = undefined;
            const chars = reader.interface.readSliceShort(&buffer) catch 0;
            const environ_entry = buffer[0..chars];
            if (std.mem.startsWith(u8, environ_entry, otel_injector_log_level_environ_prefix)) {
                log_level_env_var_value = environ_entry[otel_injector_log_level_environ_prefix.len..chars];
            }
        },
    }

    if (log_level_env_var_value) |log_level_value| {
        if (std.ascii.eqlIgnoreCase("debug", log_level_value)) {
            proc_self_environ_values.setLogLevel(.Debug);
        } else if (std.ascii.eqlIgnoreCase("info", log_level_value)) {
            proc_self_environ_values.setLogLevel(.Info);
        } else if (std.ascii.eqlIgnoreCase("warn", log_level_value)) {
            proc_self_environ_values.setLogLevel(.Warn);
        } else if (std.ascii.eqlIgnoreCase("error", log_level_value)) {
            proc_self_environ_values.setLogLevel(.Error);
        } else if (std.ascii.eqlIgnoreCase("none", log_level_value)) {
            proc_self_environ_values.setLogLevel(.None);
        } else {
            print.printError("unknown value for OTEL_INJECTOR_LOG_LEVEL: \"{s}\" -- valid log levels are \"debug\", \"info\", \"warn\", \"error\", \"none\".", .{log_level_value});
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
