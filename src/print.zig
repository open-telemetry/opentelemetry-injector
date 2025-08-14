// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const otel_injector_debug_env_var_name = "OTEL_INJECTOR_DEBUG";
const log_prefix = "[otel-injector] ";

var is_debug = false;

/// Initializes the is_debug flag based on the environment variable OTEL_INJECTOR_DEBUG.
pub fn initDebugFlag() void {
    if (std.posix.getenv(otel_injector_debug_env_var_name)) |is_debug_raw| {
        is_debug = std.ascii.eqlIgnoreCase("true", is_debug_raw);
    }
}

pub fn isDebug() bool {
    return is_debug;
}

pub fn printDebug(comptime fmt: []const u8, args: anytype) void {
    if (is_debug) {
        std.debug.print(log_prefix ++ fmt ++ "\n", args);
    }
}

pub fn printError(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(log_prefix ++ fmt ++ "\n", args);
}

pub fn printMessage(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(log_prefix ++ fmt ++ "\n", args);
}
