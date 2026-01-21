// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const config = @import("config.zig");
const print = @import("print.zig");
const types = @import("types.zig");
const test_util = @import("test_util.zig");

const testing = std.testing;

pub const pythonpath_env_var_name = "PYTHONPATH";

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
        configuration.python_auto_instrumentation_agent_path,
    );
}

fn doCheckPythonAutoInstrumentationAgentAndGetModifiedPythonpathValue(
    gpa: std.mem.Allocator,
    original_value_optional: ?[:0]const u8,
    python_auto_instrumentation_agent_path: []u8,
) ?[:0]u8 {
    if (python_auto_instrumentation_agent_path.len == 0) {
        print.printInfo("Skipping the injection of the Python OpenTelemetry auto-instrumentation because it has been explicitly disabled.", .{});
        return null;
    }

    // Check the existence of the Python directory, stand down if it does not exist.
    std.fs.cwd().access(python_auto_instrumentation_agent_path, .{}) catch |err| {
        print.printError("Skipping the injection of the Python OpenTelemetry auto-instrumentation in \"{s}\" because of an issue accessing the directory at \"{s}\": {}", .{ pythonpath_env_var_name, python_auto_instrumentation_agent_path, err });
        return null;
    };

    const python_auto_instrumentation_agent_path_with_null_terminator = std.fmt.allocPrintSentinel(gpa, "{s}", .{python_auto_instrumentation_agent_path}, 0) catch |err| {
        print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ pythonpath_env_var_name, err });
        return null;
    };

    return getModifiedPythonpathValue(
        gpa,
        original_value_optional,
        python_auto_instrumentation_agent_path_with_null_terminator,
    );
}

test "doCheckPythonAutoInstrumentationAgentAndGetModifiedPythonpathValue: should return null if the Python OTel auto-instrumentation agent cannot be accessed (no other PYTHONPATH are present)" {
    const path = try std.fmt.allocPrint(testing.allocator, "/invalid/path", .{});
    defer testing.allocator.free(path);
    const modified_pythonpath_value =
        doCheckPythonAutoInstrumentationAgentAndGetModifiedPythonpathValue(
            testing.allocator,
            null,
            path,
        );
    try test_util.expectWithMessage(modified_pythonpath_value == null, "modified_pythonpath_value == null");
}

test "doCheckPythonAutoInstrumentationAgentAndGetModifiedPythonpathValue: should return null if the Python OTel auto-instrumentation agent cannot be accessed (other PYTHONPATH are present)" {
    const path = try std.fmt.allocPrint(testing.allocator, "/invalid/path", .{});
    defer testing.allocator.free(path);
    const modified_pythonpath_value =
        doCheckPythonAutoInstrumentationAgentAndGetModifiedPythonpathValue(
            testing.allocator,
            "/another/path"[0.. :0],
            path,
        );
    try test_util.expectWithMessage(modified_pythonpath_value == null, "modified_pythonpath_value == null");
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
    const python_auto_instrumentation_agent_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "/usr/lib/opentelemetry/python",
        .{},
        0,
    );
    const modified_pythonpath_value =
        getModifiedPythonpathValue(
            testing.allocator,
            null,
            python_auto_instrumentation_agent_path,
        );
    defer (if (modified_pythonpath_value) |val| {
        testing.allocator.free(val);
    });
    try testing.expectEqualStrings(
        "/usr/lib/opentelemetry/python",
        modified_pythonpath_value orelse "-",
    );
}

test "getModifiedPythonpathValue: should prepend the auto-instrumentation directory if original value exists" {
    const original_value: [:0]const u8 = "/another/path/1:/another/path/2"[0.. :0];
    const python_auto_instrumentation_agent_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "/usr/lib/opentelemetry/python",
        .{},
        0,
    );
    const modified_pythonpath_value =
        getModifiedPythonpathValue(
            testing.allocator,
            original_value,
            python_auto_instrumentation_agent_path,
        );
    defer (if (modified_pythonpath_value) |val| {
        testing.allocator.free(val);
    });
    try testing.expectEqualStrings(
        "/usr/lib/opentelemetry/python:/another/path/1:/another/path/2",
        modified_pythonpath_value orelse "-",
    );
}

test "getModifiedPythonpathValue: should do nothing if the auto-instrumentation directory is already present" {
    const original_value: [:0]const u8 = "/path/before:/usr/lib/opentelemetry/python:/path/after"[0.. :0];
    const python_auto_instrumentation_agent_path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "/usr/lib/opentelemetry/python",
        .{},
        0,
    );
    const modified_pythonpath_value =
        getModifiedPythonpathValue(
            testing.allocator,
            original_value,
            python_auto_instrumentation_agent_path,
        );
    try test_util.expectWithMessage(modified_pythonpath_value == null, "modified_pythonpath_value == null");
}
