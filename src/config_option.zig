// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const patterns_util = @import("patterns_util.zig");
const print = @import("print.zig");
const types = @import("types.zig");

pub const Kind = enum { string, uint32, boolean, log_level, glob_list, runtime_list };
pub const Repeated = enum { replace, append };
pub const Empty = enum { value, default };
pub const LogLevel = enum(u8) { Debug, Info, Warn, Error, None };
pub const RuntimeSet = struct {
    dotnet: bool = false,
    jvm: bool = false,
    nodejs: bool = false,
    python: bool = false,
    ruby: bool = false,
};

fn Value(comptime kind: Kind) type {
    return switch (kind) {
        .string => []u8,
        .uint32 => u32,
        .boolean => bool,
        .log_level => LogLevel,
        .glob_list => [][]const u8,
        .runtime_list => RuntimeSet,
    };
}

fn Default(comptime kind: Kind) type {
    return switch (kind) {
        .string => []const u8,
        .glob_list => []const []const u8,
        else => Value(kind),
    };
}

pub fn Option(comptime kind: Kind) type {
    return struct {
        const Self = @This();
        pub const ValueType = Value(kind);
        const ScalarResult = if (kind == .boolean) bool else error{InvalidValue}!ValueType;

        file_key: ?[:0]const u8 = null,
        env_name: ?[:0]const u8 = null,
        repeated: Repeated = .replace,
        trim: bool = true,
        empty: Empty = .value,
        default_value: Default(kind),

        /// Borrows defaults. Copy before modifying or freeing string/list values.
        pub fn initialValue(comptime self: Self) ValueType {
            return switch (kind) {
                .string, .glob_list => @constCast(self.default_value),
                else => self.default_value,
            };
        }

        pub fn parseScalar(_: Self, raw: []const u8) ScalarResult {
            return switch (kind) {
                .uint32 => std.fmt.parseUnsigned(u32, std.mem.trim(u8, raw, " \t\r\n"), 10) catch error.InvalidValue,
                .boolean => std.ascii.eqlIgnoreCase(raw, "true") or std.ascii.eqlIgnoreCase(raw, "t") or std.mem.eql(u8, raw, "1"),
                .log_level => blk: {
                    inline for (@typeInfo(LogLevel).@"enum".field_names) |name| {
                        if (std.ascii.eqlIgnoreCase(raw, name)) break :blk @field(LogLevel, name);
                    }
                    break :blk error.InvalidValue;
                },
                else => @compileError("parseScalar requires a boolean, uint32, or log-level option"),
            };
        }

        pub fn parseEnvironmentScalar(comptime self: Self, raw: []const u8) ScalarResult {
            const value = if (self.trim) std.mem.trim(u8, raw, " \t\r\n") else raw;
            if (self.empty == .default and value.len == 0) return self.initialValue();
            return self.parseScalar(value);
        }

        pub fn parse(self: Self, allocator: std.mem.Allocator, raw: []const u8, source: []const u8) (std.mem.Allocator.Error || error{InvalidValue})!ValueType {
            switch (kind) {
                .string => return allocator.dupe(u8, raw),
                .uint32, .boolean, .log_level => return self.parseScalar(raw),
                .glob_list => return patterns_util.splitByComma(allocator, raw),
                .runtime_list => {
                    var result: RuntimeSet = .{};
                    if (std.mem.eql(u8, raw, "*")) {
                        inline for (@typeInfo(RuntimeSet).@"struct".field_names) |name| {
                            @field(result, name) = true;
                        }
                        return result;
                    }
                    var it = std.mem.splitScalar(u8, raw, ',');
                    while (it.next()) |part| {
                        const name = std.mem.trim(u8, part, " \t");
                        if (name.len == 0) continue;
                        var matched = false;
                        inline for (@typeInfo(RuntimeSet).@"struct".field_names) |runtime| {
                            if (std.mem.eql(u8, name, runtime)) {
                                @field(result, runtime) = true;
                                matched = true;
                            }
                        }
                        if (!matched) {
                            print.printWarn("Unknown runtime in the list of disabled runtimes from {s}: \"{s}\" - this list item will be ignored.", .{ source, name });
                        }
                    }
                    return result;
                },
            }
        }

        /// String options retain the file parser's allocated value.
        pub fn parseFile(self: Self, allocator: std.mem.Allocator, value: []u8, source: []const u8) (std.mem.Allocator.Error || error{InvalidValue})!ValueType {
            if (kind == .string) return value;
            return self.parse(allocator, value, source);
        }

        pub fn warnInvalidValue(self: Self, raw: []const u8, source: []const u8) void {
            const name = self.file_key orelse self.env_name.?;
            if (kind == .uint32) {
                print.printWarn("Ignoring invalid value for {s} from {s}: \"{s}\" - a non-negative integer is required.", .{ name, source, std.mem.trim(u8, raw, " \t\r\n") });
            } else {
                print.printWarn("Ignoring invalid value for {s} from {s}: \"{s}\"", .{ name, source, raw });
            }
        }

        /// Borrows a normalized string or its default without allocating.
        pub fn environmentString(self: Self, raw: []const u8) []const u8 {
            if (kind != .string) @compileError("environmentString requires a string option");
            const value = if (self.trim) std.mem.trim(u8, raw, " \t\r\n") else raw;
            return if (self.empty == .default and value.len == 0) self.default_value else value;
        }

        pub fn parseEnvironment(comptime self: Self, allocator: std.mem.Allocator, raw: []const u8) (std.mem.Allocator.Error || error{InvalidValue})!ValueType {
            const value = if (self.trim) std.mem.trim(u8, raw, " \t\r\n") else raw;
            if (self.empty == .default and value.len == 0) return try self.copy(allocator, self.initialValue());
            return try self.parse(allocator, value, self.env_name.?);
        }

        /// Borrows a string value, applying environment trimming and empty-value policy.
        pub fn readLibcEnvironment(self: Self, getenv_fn: types.GetenvFnPtr) ?[]const u8 {
            if (kind != .string) @compileError("readLibcEnvironment requires a string option");
            const raw = std.mem.span(getenv_fn(self.env_name.?) orelse return null);
            return self.environmentString(raw);
        }

        pub fn copy(_: Self, allocator: std.mem.Allocator, value: ValueType) std.mem.Allocator.Error!ValueType {
            return switch (kind) {
                .string => allocator.dupe(u8, value),
                .glob_list => blk: {
                    const result = try allocator.alloc([]const u8, value.len);
                    var copied: usize = 0;
                    errdefer {
                        for (result[0..copied]) |item| allocator.free(item);
                        allocator.free(result);
                    }
                    for (value, 0..) |item, i| {
                        result[i] = try allocator.dupe(u8, item);
                        copied += 1;
                    }
                    break :blk result;
                },
                else => value,
            };
        }

        pub fn deinit(_: Self, allocator: std.mem.Allocator, value: ValueType) void {
            switch (kind) {
                .string => allocator.free(value),
                .glob_list => {
                    for (value) |item| allocator.free(item);
                    allocator.free(value);
                },
                else => {},
            }
        }
    };
}

test "string values: file parsing and environment selectors borrow without allocating" {
    const testing = std.testing;
    var raw = " /app/config ".*;
    const option = Option(.string){ .env_name = "TEST", .default_value = "default" };
    const file_value = try option.parseFile(testing.failing_allocator, &raw, "test");
    try testing.expectEqual(raw[0..].ptr, file_value.ptr);
    try testing.expectEqualStrings(" /app/config ", file_value);

    const selector = option.environmentString(&raw);
    try testing.expectEqual(raw[1..].ptr, selector.ptr);
    try testing.expectEqualStrings("/app/config", selector);
    try testing.expectEqualStrings("", option.environmentString(" \t\r\n"));

    const fallback = Option(.string){ .env_name = "TEST", .default_value = "default", .empty = .default };
    try testing.expectEqualStrings("default", fallback.environmentString(" \t\r\n"));
}

test "parseEnvironmentScalar: trimming, defaults, and invalid log levels" {
    const testing = std.testing;
    const boolean = Option(.boolean){ .default_value = true, .empty = .default };
    try testing.expect(boolean.parseEnvironmentScalar(" \t\r\n"));
    try testing.expect(boolean.parseEnvironmentScalar(" TRUE "));
    try testing.expect(!boolean.parseEnvironmentScalar("false"));

    const log_level = Option(.log_level){ .default_value = .Error, .trim = false };
    try testing.expectEqual(.Debug, try log_level.parseEnvironmentScalar("DEBUG"));
    try testing.expectError(error.InvalidValue, log_level.parseEnvironmentScalar(" debug "));
    try testing.expectError(error.InvalidValue, log_level.parseEnvironmentScalar(""));
}

test "parse: uint32 bounds and invalid values" {
    const testing = std.testing;
    const option = Option(.uint32){ .default_value = 8 };
    try testing.expectEqual(@as(u32, 0), try option.parse(testing.allocator, "0", "test"));
    try testing.expectEqual(std.math.maxInt(u32), try option.parse(testing.allocator, "4294967295", "test"));
    try testing.expectEqual(@as(u32, 0), try option.parse(testing.allocator, "0\n", "test"));
    try testing.expectEqual(@as(u32, 21), try option.parse(testing.allocator, " 21\t\r\n", "test"));
    for ([_][]const u8{ "", "true", "-1", "4294967296", "1.0" }) |value| {
        try testing.expectError(error.InvalidValue, option.parse(testing.allocator, value, "test"));
    }
}
