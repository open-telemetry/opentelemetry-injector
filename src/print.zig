// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const proc_self_environ_values = @import("proc_self_environ_values.zig");
const types = @import("types.zig");

const log_prefix = "[otel-injector] ";

pub inline fn getLogLevel() proc_self_environ_values.LogLevel {
    return proc_self_environ_values.getLogLevel();
}

pub inline fn isDebug() bool {
    return getLogLevel() == .Debug;
}

pub fn printDebug(comptime fmt: []const u8, args: anytype) void {
    if (getLogLevel() == .Debug) {
        _printMessage(fmt, args);
    }
}

pub fn printInfo(comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(getLogLevel()) <= @intFromEnum(proc_self_environ_values.LogLevel.Info)) {
        _printMessage(fmt, args);
    }
}

pub fn printWarn(comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(getLogLevel()) <= @intFromEnum(proc_self_environ_values.LogLevel.Warn)) {
        _printMessage(fmt, args);
    }
}

pub fn printError(comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(getLogLevel()) <= @intFromEnum(proc_self_environ_values.LogLevel.Error)) {
        _printMessage(fmt, args);
    }
}

fn _printMessage(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(log_prefix ++ "[{d:>7}] " ++ fmt ++ "\n", .{proc_self_environ_values.getPid()} ++ args);
}
