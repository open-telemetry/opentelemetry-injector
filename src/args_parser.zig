// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

/// Parses /proc/<pid>/cmdline and extracts the executable and arguments.
/// Returns the slice of the arguments including the executable as the first argument.
/// The cmdline file contains null-separated arguments.
/// Caller owns the returned memory and must free it.
pub fn cmdLineForPID(allocator: std.mem.Allocator) ![]const []const u8 {
    const cmdline_path = "/proc/self/cmdline";

    const file = std.fs.openFileAbsolute(cmdline_path, .{}) catch |err| {
        return err;
    };
    defer file.close();

    // Read the entire file (typically small, < 4KB for most processes)
    const max_size = 64 * 1024; // 64KB should be more than enough
    const content = try file.readToEndAlloc(allocator, max_size);
    defer allocator.free(content);

    if (content.len == 0) {
        return error.EmptyCmdline;
    }

    // Split by null bytes to get arguments
    var arg_list = std.ArrayList([]const u8).init(allocator);
    errdefer arg_list.deinit();

    var iter = std.mem.splitScalar(u8, content, 0);
    while (iter.next()) |arg| {
        if (arg.len > 0) { // Skip empty strings
            const arg_copy = try allocator.dupe(u8, arg);
            try arg_list.append(arg_copy);
        }
    }

    const all_args = try arg_list.toOwnedSlice();

    if (all_args.len == 0) {
        return error.NoCmdlineArgs;
    }

    // First argument is the executable, rest are arguments
    return all_args;
}
