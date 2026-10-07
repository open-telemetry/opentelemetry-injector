// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const testing = std.testing;

pub inline fn parseBooleanValue(value: []const u8) bool {
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
