// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

/// Parses /proc/<pid>/cmdline and extracts the executable and arguments.
/// Returns the slice of the arguments including the executable as the first argument.
/// The cmdline file contains null-separated arguments.
/// Caller owns the returned memory and must free it.
pub fn cmdLineForPID(allocator: std.mem.Allocator) ![]const []const u8 {
    const cmdline_path = "/proc/self/cmdline";
    return getCmdLineForPID(allocator, cmdline_path);
}

fn getCmdLineForPID(allocator: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        return err;
    };
    defer file.close();

    // Read the entire file (typically small, < 4KB for most processes)
    const max_size = 64 * 1024; // 64KB should be more than enough
    const content = try file.readToEndAlloc(allocator, max_size);
    defer allocator.free(content);

    return getCmdLineFromContent(allocator, content);
}

fn getCmdLineFromContent(allocator: std.mem.Allocator, content: []const u8) ![]const []const u8 {
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

const testing = std.testing;

test "getCmdLineFromContent: basic command with arguments" {
    const allocator = testing.allocator;
    const cmdline_data = "/usr/bin/test\x00-arg1\x00value1\x00-arg2\x00value2\x00";

    const result = try getCmdLineFromContent(allocator, cmdline_data);
    defer {
        for (result) |arg| allocator.free(arg);
        allocator.free(result);
    }

    try testing.expectEqual(5, result.len);
    try testing.expectEqualStrings("/usr/bin/test", result[0]);
    try testing.expectEqualStrings("-arg1", result[1]);
    try testing.expectEqualStrings("value1", result[2]);
    try testing.expectEqualStrings("-arg2", result[3]);
    try testing.expectEqualStrings("value2", result[4]);
}

test "getCmdLineFromContent: command without arguments" {
    const allocator = testing.allocator;
    const cmdline_data = "/usr/bin/test\x00";

    const result = try getCmdLineFromContent(allocator, cmdline_data);
    defer {
        for (result) |arg| allocator.free(arg);
        allocator.free(result);
    }

    try testing.expectEqual(1, result.len);
    try testing.expectEqualStrings("/usr/bin/test", result[0]);
}

test "getCmdLineFromContent: command with single argument" {
    const allocator = testing.allocator;
    const cmdline_data = "/usr/bin/grep\x00pattern\x00";

    const result = try getCmdLineFromContent(allocator, cmdline_data);
    defer {
        for (result) |arg| allocator.free(arg);
        allocator.free(result);
    }

    try testing.expectEqual(2, result.len);
    try testing.expectEqualStrings("/usr/bin/grep", result[0]);
    try testing.expectEqualStrings("pattern", result[1]);
}

test "getCmdLineFromContent: empty content returns error" {
    const allocator = testing.allocator;
    const cmdline_data = "";

    const result = getCmdLineFromContent(allocator, cmdline_data);
    try testing.expectError(error.EmptyCmdline, result);
}

test "getCmdLineFromContent: null bytes returns error" {
    const allocator = testing.allocator;
    const cmdline_data = "\x00\x00\x00";

    const result = getCmdLineFromContent(allocator, cmdline_data);
    try testing.expectError(error.NoCmdlineArgs, result);
}

test "getCmdLineFromContent: trailing nulls are ignored" {
    const allocator = testing.allocator;
    const cmdline_data = "/usr/bin/test\x00arg1\x00\x00\x00";

    const result = try getCmdLineFromContent(allocator, cmdline_data);
    defer {
        for (result) |arg| allocator.free(arg);
        allocator.free(result);
    }

    try testing.expectEqual(2, result.len);
    try testing.expectEqualStrings("/usr/bin/test", result[0]);
    try testing.expectEqualStrings("arg1", result[1]);
}

test "getCmdLineFromContent: java command with jar" {
    const allocator = testing.allocator;
    const cmdline_data = "/usr/bin/java\x00-jar\x00/app/myapp.jar\x00--server.port=8080\x00";

    const result = try getCmdLineFromContent(allocator, cmdline_data);
    defer {
        for (result) |arg| allocator.free(arg);
        allocator.free(result);
    }

    try testing.expectEqual(4, result.len);
    try testing.expectEqualStrings("/usr/bin/java", result[0]);
    try testing.expectEqualStrings("-jar", result[1]);
    try testing.expectEqualStrings("/app/myapp.jar", result[2]);
    try testing.expectEqualStrings("--server.port=8080", result[3]);
}

test "getCmdLineFromContent: node command with script" {
    const allocator = testing.allocator;
    const cmdline_data = "/usr/bin/node\x00/app/index.js\x00--port\x003000\x00";

    const result = try getCmdLineFromContent(allocator, cmdline_data);
    defer {
        for (result) |arg| allocator.free(arg);
        allocator.free(result);
    }

    try testing.expectEqual(4, result.len);
    try testing.expectEqualStrings("/usr/bin/node", result[0]);
    try testing.expectEqualStrings("/app/index.js", result[1]);
    try testing.expectEqualStrings("--port", result[2]);
    try testing.expectEqualStrings("3000", result[3]);
}

test "getCmdLineFromContent: dotnet command with dll" {
    const allocator = testing.allocator;
    const cmdline_data = "/usr/bin/dotnet\x00/app/MyApp.dll\x00";

    const result = try getCmdLineFromContent(allocator, cmdline_data);
    defer {
        for (result) |arg| allocator.free(arg);
        allocator.free(result);
    }

    try testing.expectEqual(2, result.len);
    try testing.expectEqualStrings("/usr/bin/dotnet", result[0]);
    try testing.expectEqualStrings("/app/MyApp.dll", result[1]);
}
