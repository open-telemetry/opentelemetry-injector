// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const print = @import("print.zig");
const testing = std.testing;

/// Splits a comma-separated string into a slice of trimmed strings.
pub fn splitByComma(allocator: std.mem.Allocator, input: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = try .initCapacity(allocator, input.len);
    errdefer list.deinit(allocator);

    var iter = std.mem.splitScalar(u8, input, ',');
    while (iter.next()) |item| {
        const trimmed = std.mem.trim(u8, item, " \t\r\n");
        if (trimmed.len > 0) {
            const owned = std.fmt.allocPrint(allocator, "{s}", .{trimmed}) catch |err| {
                print.printError("error allocating memory for path pattern from: {}", .{err});
                return err;
            };
            try list.append(allocator, owned);
        }
    }

    return list.toOwnedSlice(allocator);
}

test "splitByComma: empty string" {
    const allocator = testing.allocator;
    const result = try splitByComma(allocator, "");
    defer allocator.free(result);
    try testing.expectEqual(0, result.len);
}

test "splitByComma: single value" {
    const allocator = testing.allocator;
    const result = try splitByComma(allocator, "/usr/bin/.*");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }
    try testing.expectEqual(1, result.len);
    try testing.expectEqualStrings("/usr/bin/.*", result[0]);
}

test "splitByComma: multiple values" {
    const allocator = testing.allocator;
    const result = try splitByComma(allocator, "/usr/bin/.*,/opt/.*,/home/.*");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }
    try testing.expectEqual(3, result.len);
    try testing.expectEqualStrings("/usr/bin/.*", result[0]);
    try testing.expectEqualStrings("/opt/.*", result[1]);
    try testing.expectEqualStrings("/home/.*", result[2]);
}

test "splitByComma: values with whitespace characters" {
    const allocator = testing.allocator;
    const result = try splitByComma(allocator, "  /usr/bin/.* \n ,  /opt/.*  \t,  /home/.*  ");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }
    try testing.expectEqual(3, result.len);
    try testing.expectEqualStrings("/usr/bin/.*", result[0]);
    try testing.expectEqualStrings("/opt/.*", result[1]);
    try testing.expectEqualStrings("/home/.*", result[2]);
}

test "splitByComma: empty items filtered out" {
    const allocator = testing.allocator;
    const result = try splitByComma(allocator, "/usr/bin/.*,,/opt/.*, \n\t\r ,/home/.*");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }
    try testing.expectEqual(3, result.len);
    try testing.expectEqualStrings("/usr/bin/.*", result[0]);
    try testing.expectEqualStrings("/opt/.*", result[1]);
    try testing.expectEqualStrings("/home/.*", result[2]);
}

test "splitByComma: trailing comma" {
    const allocator = testing.allocator;
    const result = try splitByComma(allocator, "/usr/bin/.*,/opt/.*,");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }
    try testing.expectEqual(2, result.len);
    try testing.expectEqualStrings("/usr/bin/.*", result[0]);
    try testing.expectEqualStrings("/opt/.*", result[1]);
}

test "splitByComma: leading comma" {
    const allocator = testing.allocator;
    const result = try splitByComma(allocator, ",/usr/bin/.*,/opt/.*");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }
    try testing.expectEqual(2, result.len);
    try testing.expectEqualStrings("/usr/bin/.*", result[0]);
    try testing.expectEqualStrings("/opt/.*", result[1]);
}
