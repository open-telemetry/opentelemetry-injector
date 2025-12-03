// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const alloc = @import("allocator.zig");
const print = @import("print.zig");
const testing = std.testing;

/// Splits a comma-separated string into a slice of trimmed strings.
pub fn splitByComma(input: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .init(alloc.page_allocator);
    errdefer list.deinit();

    var iter = std.mem.splitScalar(u8, input, ',');
    while (iter.next()) |item| {
        const trimmed = std.mem.trim(u8, item, " \t\r\n");
        if (trimmed.len > 0) {
            const owned = std.fmt.allocPrint(alloc.page_allocator, "{s}", .{trimmed}) catch |err| {
                print.printError("error allocating memory for path pattern from: {}", .{err});
                return err;
            };
            try list.append(owned);
        }
    }

    return list.toOwnedSlice();
}

test "splitByComma: empty string" {
    const result = try splitByComma("");
    try testing.expectEqual(0, result.len);
}

test "splitByComma: single value" {
    const result = try splitByComma("/usr/bin/.*");
    try testing.expectEqual(1, result.len);
    try testing.expectEqualStrings("/usr/bin/.*", result[0]);
}

test "splitByComma: multiple values" {
    const result = try splitByComma("/usr/bin/.*,/opt/.*,/home/.*");
    try testing.expectEqual(3, result.len);
    try testing.expectEqualStrings("/usr/bin/.*", result[0]);
    try testing.expectEqualStrings("/opt/.*", result[1]);
    try testing.expectEqualStrings("/home/.*", result[2]);
}

test "splitByComma: values with whitespace characters" {
    const result = try splitByComma("  /usr/bin/.* \n ,  /opt/.*  \t,  /home/.*  ");
    try testing.expectEqual(3, result.len);
    try testing.expectEqualStrings("/usr/bin/.*", result[0]);
    try testing.expectEqualStrings("/opt/.*", result[1]);
    try testing.expectEqualStrings("/home/.*", result[2]);
}

test "splitByComma: empty items filtered out" {
    const result = try splitByComma("/usr/bin/.*,,/opt/.*, \n\t\r ,/home/.*");
    try testing.expectEqual(3, result.len);
    try testing.expectEqualStrings("/usr/bin/.*", result[0]);
    try testing.expectEqualStrings("/opt/.*", result[1]);
    try testing.expectEqualStrings("/home/.*", result[2]);
}

test "splitByComma: trailing comma" {
    const result = try splitByComma("/usr/bin/.*,/opt/.*,");
    try testing.expectEqual(2, result.len);
    try testing.expectEqualStrings("/usr/bin/.*", result[0]);
    try testing.expectEqualStrings("/opt/.*", result[1]);
}

test "splitByComma: leading comma" {
    const result = try splitByComma(",/usr/bin/.*,/opt/.*");
    try testing.expectEqual(2, result.len);
    try testing.expectEqualStrings("/usr/bin/.*", result[0]);
    try testing.expectEqualStrings("/opt/.*", result[1]);
}
