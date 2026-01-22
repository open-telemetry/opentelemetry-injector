// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const config = @import("config.zig");
const print = @import("print.zig");
const types = @import("types.zig");
const test_util = @import("test_util.zig");

const testing = std.testing;

pub const pythonpath_env_var_name = "PYTHONPATH";

var libc_flavor: ?types.LibCFlavor = null;

pub fn setLibcFlavor(lf: types.LibCFlavor) void {
    libc_flavor = lf;
}

/// Returns the modified value for PYTHONPATH with the Python auto-instrumentation prepended to the original value of
/// PYTHONPATH (if any).
///
/// The caller is responsible for freeing the returned string (unless the result is passed on to setenv and needs to
/// stay in memory).
pub fn checkPythonAutoInstrumentationAgentAndGetModifiedPythonpathValue(
    gpa: std.mem.Allocator,
    original_value_optional: ?[:0]const u8,
    configuration: config.InjectorConfiguration,
) ?[:0]u8 {
    return doCheckPythonAutoInstrumentationAgentAndGetModifiedPythonpathValue(
        gpa,
        original_value_optional,
        configuration.python_auto_instrumentation_agent_path_prefix,
    );
}

fn doCheckPythonAutoInstrumentationAgentAndGetModifiedPythonpathValue(
    gpa: std.mem.Allocator,
    original_value_optional: ?[:0]const u8,
    python_auto_instrumentation_agent_path_prefix: []u8,
) ?[:0]u8 {
    if (python_auto_instrumentation_agent_path_prefix.len == 0) {
        print.printInfo("Skipping the injection of the Python OpenTelemetry auto-instrumentation because it has been explicitly disabled.", .{});
        return null;
    }

    if (libc_flavor == null) {
        print.printError("invariant violated: libc flavor has not been set prior to calling doCheckPythonAutoInstrumentationAgentAndGetModifiedPythonpathValue().", .{});
        return null;
    }
    if (libc_flavor == types.LibCFlavor.UNKNOWN) {
        print.printError("Cannot determine libc flavor", .{});
        return null;
    }
    if (libc_flavor) |libc_f| {
        const libc_flavor_suffix =
            switch (libc_f) {
                .GNU => "glibc",
                .MUSL => "musl",
                else => unreachable,
            };
        const python_auto_instrumentation_agent_path_optional =
            determinePythonpathWithLibcSuffix(
                gpa,
                python_auto_instrumentation_agent_path_prefix,
                libc_flavor_suffix,
            );
        if (python_auto_instrumentation_agent_path_optional) |python_auto_instrumentation_agent_path| {
            // Check the existence of the Python directory, stand down if it does not exist.
            std.fs.cwd().access(python_auto_instrumentation_agent_path, .{}) catch |err| {
                defer gpa.free(python_auto_instrumentation_agent_path);
                print.printError("Skipping the injection of the Python OpenTelemetry auto-instrumentation in \"{s}\" because of an issue accessing the directory at \"{s}\": {}", .{ pythonpath_env_var_name, python_auto_instrumentation_agent_path, err });
                return null;
            };
            return getModifiedPythonpathValue(
                gpa,
                original_value_optional,
                python_auto_instrumentation_agent_path,
            );
        } else {
            return null;
        }
    }

    unreachable;
}

test "doCheckPythonAutoInstrumentationAgentAndGetModifiedPythonpathValue: should return null value if the libc flavor has not been set" {
    const allocator = testing.allocator;
    _resetState();
    defer _resetState();

    const path_prefix: []u8 = try std.fmt.allocPrint(allocator, "/some/path", .{});
    defer allocator.free(path_prefix);

    const modified_pythonpath_value =
        doCheckPythonAutoInstrumentationAgentAndGetModifiedPythonpathValue(
            allocator,
            null,
            path_prefix,
        );
    try test_util.expectWithMessage(modified_pythonpath_value == null, "modified_pythonpath_value == null");
}

test "doCheckPythonAutoInstrumentationAgentAndGetModifiedPythonpathValue: should return null value for unknown libc flavor" {
    const allocator = testing.allocator;
    _resetState();
    defer _resetState();

    const path_prefix = try std.fmt.allocPrint(allocator, "", .{});
    defer allocator.free(path_prefix);

    libc_flavor = .UNKNOWN;
    const modified_pythonpath_value =
        doCheckPythonAutoInstrumentationAgentAndGetModifiedPythonpathValue(
            allocator,
            null,
            path_prefix,
        );
    try test_util.expectWithMessage(modified_pythonpath_value == null, "modified_pythonpath_value == null");
}

test "doCheckPythonAutoInstrumentationAgentAndGetModifiedPythonpathValue: should return null if the Python OTel auto-instrumentation agent cannot be accessed (no other PYTHONPATH are present)" {
    const allocator = testing.allocator;
    _resetState();
    defer _resetState();

    const path_prefix = try std.fmt.allocPrint(allocator, "/invalid/path", .{});
    defer allocator.free(path_prefix);

    libc_flavor = .GNU;
    const modified_pythonpath_value =
        doCheckPythonAutoInstrumentationAgentAndGetModifiedPythonpathValue(
            allocator,
            null,
            path_prefix,
        );
    try test_util.expectWithMessage(modified_pythonpath_value == null, "modified_pythonpath_value == null");
}

test "doCheckPythonAutoInstrumentationAgentAndGetModifiedPythonpathValue: should return null if the Python OTel auto-instrumentation agent cannot be accessed (other PYTHONPATH are present)" {
    const allocator = testing.allocator;
    _resetState();
    defer _resetState();

    const path_prefix = try std.fmt.allocPrint(allocator, "/invalid/path", .{});
    defer allocator.free(path_prefix);

    libc_flavor = .GNU;
    const modified_pythonpath_value =
        doCheckPythonAutoInstrumentationAgentAndGetModifiedPythonpathValue(
            allocator,
            "/another/path"[0.. :0],
            path_prefix,
        );
    try test_util.expectWithMessage(modified_pythonpath_value == null, "modified_pythonpath_value == null");
}

fn determinePythonpathWithLibcSuffix(
    gpa: std.mem.Allocator,
    python_auto_instrumentation_agent_path_prefix: []u8,
    libc_flavor_suffix: []const u8,
) ?[:0]u8 {
    return std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{
        python_auto_instrumentation_agent_path_prefix, libc_flavor_suffix,
    }, 0) catch |err| {
        print.printError("Cannot allocate memory to manipulate the value of \"{s}\" for libc flavor \"{s}\": {}", .{
            pythonpath_env_var_name,
            libc_flavor_suffix,
            err,
        });
        return null;
    };
}

test "determinePythonpathWithLibcSuffix: should return full path for glibc" {
    const allocator = testing.allocator;
    const path_prefix = try std.fmt.allocPrint(allocator, "/usr/lib/opentelemetry/python", .{});
    defer allocator.free(path_prefix);
    const libc_flavor_suffix = try std.fmt.allocPrint(allocator, "glibc", .{});
    defer allocator.free(libc_flavor_suffix);

    const python_auto_instrumentation_agent_path_optional =
        determinePythonpathWithLibcSuffix(
            allocator,
            path_prefix,
            libc_flavor_suffix,
        );
    if (python_auto_instrumentation_agent_path_optional) |python_auto_instrumentation_agent_path| {
        defer allocator.free(python_auto_instrumentation_agent_path);
        try testing.expectEqualStrings(
            "/usr/lib/opentelemetry/python/glibc",
            python_auto_instrumentation_agent_path,
        );
    } else {
        return error.TestUnexpectedResult;
    }
}

test "determinePythonpathWithLibcSuffix: should return full path for musl" {
    const allocator = testing.allocator;
    const path_prefix = try std.fmt.allocPrint(allocator, "/usr/lib/opentelemetry/python", .{});
    defer allocator.free(path_prefix);
    const libc_flavor_suffix = try std.fmt.allocPrint(allocator, "musl", .{});
    defer allocator.free(libc_flavor_suffix);

    const python_auto_instrumentation_agent_path_optional =
        determinePythonpathWithLibcSuffix(
            allocator,
            path_prefix,
            @constCast("musl"),
        );
    if (python_auto_instrumentation_agent_path_optional) |python_auto_instrumentation_agent_path| {
        defer allocator.free(python_auto_instrumentation_agent_path);

        try testing.expectEqualStrings(
            "/usr/lib/opentelemetry/python/musl",
            python_auto_instrumentation_agent_path,
        );
    } else {
        return error.TestUnexpectedResult;
    }
}

fn getModifiedPythonpathValue(
    gpa: std.mem.Allocator,
    original_value_optional: ?[:0]const u8,
    python_auto_instrumentation_agent_path: [:0]u8,
) ?[:0]u8 {
    if (original_value_optional) |original_value| {
        if (std.mem.indexOf(u8, original_value, python_auto_instrumentation_agent_path)) |_| {
            // If the correct path flag is already present in PYTHONPATH, do nothing. This is particularly important
            // to avoid double injection, for example if we are injecting into a container which has a shell
            // executable as its entry point (into which we inject env var modifications), and then this shell starts
            // the Python executable as a child process, which inherits the environment from the already injected
            // shell.
            gpa.free(python_auto_instrumentation_agent_path);
            return null;
        }

        // If PYTHONPATH is already set, prepend the our directory to the original value. Since we copy over
        // python_auto_instrumentation_agent_path into newly allocated memory, we can free the parameter here.
        defer gpa.free(python_auto_instrumentation_agent_path);
        return std.fmt.allocPrintSentinel(
            gpa,
            "{s}:{s}",
            .{ python_auto_instrumentation_agent_path, original_value },
            0,
        ) catch |err| {
            print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ pythonpath_env_var_name, err });
            return null;
        };
    }

    // If PYTHONPATH is not set, simply return our path, which will then become the only entry in PYTHONPATH.
    return python_auto_instrumentation_agent_path[0..];
}

test "getModifiedPythonpathValue: should return the auto-instrumentation directory if original value is unset" {
    const allocator = testing.allocator;
    const python_auto_instrumentation_agent_path = try std.fmt.allocPrintSentinel(
        allocator,
        "/usr/lib/opentelemetry/python/glibc",
        .{},
        0,
    );
    const modified_pythonpath_value =
        getModifiedPythonpathValue(
            allocator,
            null,
            python_auto_instrumentation_agent_path,
        );
    defer (if (modified_pythonpath_value) |val| {
        allocator.free(val);
    });
    try testing.expectEqualStrings(
        "/usr/lib/opentelemetry/python/glibc",
        modified_pythonpath_value orelse "-",
    );
}

test "getModifiedPythonpathValue: should prepend the auto-instrumentation directory if original value exists" {
    const allocator = testing.allocator;
    const original_value: [:0]const u8 = "/another/path/1:/another/path/2"[0.. :0];
    const python_auto_instrumentation_agent_path = try std.fmt.allocPrintSentinel(
        allocator,
        "/usr/lib/opentelemetry/python/glibc",
        .{},
        0,
    );
    const modified_pythonpath_value =
        getModifiedPythonpathValue(
            allocator,
            original_value,
            python_auto_instrumentation_agent_path,
        );
    defer (if (modified_pythonpath_value) |val| {
        allocator.free(val);
    });
    try testing.expectEqualStrings(
        "/usr/lib/opentelemetry/python/glibc:/another/path/1:/another/path/2",
        modified_pythonpath_value orelse "-",
    );
}

test "getModifiedPythonpathValue: should return null if the auto-instrumentation directory is already present" {
    const allocator = testing.allocator;
    const original_value: [:0]const u8 = "/path/before:/usr/lib/opentelemetry/python/glibc:/path/after"[0.. :0];
    const python_auto_instrumentation_agent_path = try std.fmt.allocPrintSentinel(
        allocator,
        "/usr/lib/opentelemetry/python/glibc",
        .{},
        0,
    );
    const modified_pythonpath_value =
        getModifiedPythonpathValue(
            allocator,
            original_value,
            python_auto_instrumentation_agent_path,
        );
    try test_util.expectWithMessage(modified_pythonpath_value == null, "modified_pythonpath_value == null");
}

/// Only used for unit tests.
fn _resetState() void {
    libc_flavor = null;
}
