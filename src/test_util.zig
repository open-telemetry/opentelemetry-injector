// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

// **Note: This file must only be imported from *_test.zig files, never from actual production code zig files.**

const std = @import("std");

const testing = std.testing;

pub const test_allocator: std.mem.Allocator = std.heap.page_allocator;

/// Clears all entries from std.c.environ, i.e. all environment variables are discarded. The original content before
/// making any changes is returned. The caller is expected to reset std.c.environ to the return value of this function
/// when the test is done, for example by calling `defer resetStdCEnviron(original_environ);` directly after calling
/// this function (where original_environ is the return value of this function).
pub fn clearStdCEnviron() anyerror![*:null]?[*:0]u8 {
    const original_environ = std.c.environ;
    const new_environ = try test_allocator.allocSentinel(?[*:0]u8, 0, null);
    std.c.environ = new_environ;
    return original_environ;
}

/// Sets the given key-value pairs as the only content of std.c.environ. Everything else in std.c.environ is discarded.
/// The original content before making any changes is returned. The caller is expected to reset std.c.environ to
/// the return value of this function when the test is done, for example by calling
/// `defer resetStdCEnviron(original_environ);` directly after calling this function (where original_environ is the
/// return value of this function).
pub fn setStdCEnviron(env_vars: []const []const u8) anyerror![*:null]?[*:0]u8 {
    const original_environ = std.c.environ;

    // For some reason, the tests run with builtin.link_libc=true although test_mod in build.zig is configured with
    // .link_libc = false. This in turn makes makes std.posix.getenv use std.c.environ instead of std.os.environ.
    // Hence, for tests that require certain environment variables to be set, we mess around with std.c.environ.
    // Note: To manipulate std.os.environ instead of std.c.environ, use allocator.alloc([*:0]u8, n); instead of
    // allocator.allocSentinel(?[*:0]u8, n, null).
    const new_environ = try test_allocator.allocSentinel(?[*:0]u8, env_vars.len, null);
    for (env_vars, 0..) |env_var, i| {
        new_environ[i] = try std.fmt.allocPrintSentinel(
            test_allocator,
            "{s}",
            .{env_var},
            0,
        );
    }
    std.c.environ = new_environ;

    return original_environ;
}

/// Resets std.c.environ to the given value. This function is meant to be used after doing clearStdCEnviron or
/// setStdCEnviron earler, to restore the original environment after the test is done.
pub fn resetStdCEnviron(original_environ: [*:null]?[*:0]u8) void {
    std.c.environ = original_environ;
}

/// An extended version of std.testing.expect that prints a message in case of failure. Useful for tests that have
/// multiple expects; this version should generally be used in favor of the original std.testing.expect function.
pub fn expectWithMessage(
    ok: bool,
    comptime message: []const u8,
) !void {
    if (!ok) {
        print("\n====== assertion failed: =========\n", .{});
        print(message, .{});
        print("\n==================================\n", .{});
        return error.TestUnexpectedResult;
    }
}

// Copied from Zig's std.testing module.
fn print(comptime fmt: []const u8, args: anytype) void {
    if (@inComptime()) {
        @compileError(std.fmt.comptimePrint(fmt, args));
    } else if (testing.backend_can_print) {
        std.debug.print(fmt, args);
    }
}

// Copied from Zig's std.testing module.
fn printWithVisibleNewlines(source: []const u8) void {
    var i: usize = 0;
    while (std.mem.indexOfScalar(u8, source[i..], '\n')) |nl| : (i += nl + 1) {
        printLine(source[i..][0..nl]);
    }
    print("{s}␃\n", .{source[i..]}); // End of Text symbol (ETX)
}

// Copied from Zig's std.testing module.
fn printLine(line: []const u8) void {
    if (line.len != 0) switch (line[line.len - 1]) {
        ' ', '\t' => return print("{s}⏎\n", .{line}), // Return symbol
        else => {},
    };
    print("{s}\n", .{line});
}
