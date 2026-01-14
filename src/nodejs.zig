// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const config = @import("config.zig");
const print = @import("print.zig");
const types = @import("types.zig");
const test_util = @import("test_util.zig");

const testing = std.testing;

pub const node_options_env_var_name = "NODE_OPTIONS";

/// Returns the modified value for NODE_OPTIONS, including the --require flag; based on the original value of
/// NODE_OPTIONS.
///
/// The caller is responsible for freeing the returned string (unless the result is passed on to setenv and needs to
/// stay in memory).
pub fn checkNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
    gpa: std.mem.Allocator,
    original_value_optional: ?[:0]const u8,
    configuration: config.InjectorConfiguration,
) ?[:0]u8 {
    return doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
        gpa,
        original_value_optional,
        configuration.nodejs_auto_instrumentation_agent_path,
    );
}

fn doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
    gpa: std.mem.Allocator,
    original_value_optional: ?[:0]const u8,
    nodejs_auto_instrumentation_agent_path: []u8,
) ?[:0]u8 {
    if (nodejs_auto_instrumentation_agent_path.len == 0) {
        print.printInfo("Skipping the injection of the Node.js OpenTelemetry auto instrumentation because it has been explicitly disabled.", .{});
        return null;
    }

    // Check the existence of the Node module: requiring or importing a module
    // that does not exist or cannot be opened will crash the Node.js process
    // with an 'ERR_MODULE_NOT_FOUND' error.
    std.fs.cwd().access(nodejs_auto_instrumentation_agent_path, .{}) catch |err| {
        print.printError("Skipping the injection of the Node.js OpenTelemetry auto instrumentation in \"{s}\" because of an issue accessing the Node.js module at \"{s}\": {}", .{ node_options_env_var_name, nodejs_auto_instrumentation_agent_path, err });
        return null;
    };

    const require_nodejs_auto_instrumentation_agent = std.fmt.allocPrintSentinel(gpa, "--require {s}", .{nodejs_auto_instrumentation_agent_path}, 0) catch |err| {
        print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ node_options_env_var_name, err });
        return null;
    };

    return getModifiedNodeOptionsValue(
        gpa,
        original_value_optional,
        require_nodejs_auto_instrumentation_agent,
    );
}

test "doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue: should return null if the Node.js OTel auto instrumentation agent cannot be accessed (no other NODE_OPTIONS are present)" {
    const path = try std.fmt.allocPrint(testing.allocator, "/invalid/path", .{});
    defer testing.allocator.free(path);
    const modified_node_options_value =
        doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
            testing.allocator,
            null,
            path,
        );
    try test_util.expectWithMessage(modified_node_options_value == null, "modified_node_options_value == null");
}

test "doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue: should return null if the Node.js OTel auto instrumentation agent cannot be accessed (other NODE_OPTIONS are present)" {
    const path = try std.fmt.allocPrint(testing.allocator, "/invalid/path", .{});
    defer testing.allocator.free(path);
    const modified_node_options_value =
        doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
            testing.allocator,
            "--abort-on-uncaught-exception"[0.. :0],
            path,
        );
    try test_util.expectWithMessage(modified_node_options_value == null, "modified_node_options_value == null");
}

fn getModifiedNodeOptionsValue(
    gpa: std.mem.Allocator,
    original_value_optional: ?[:0]const u8,
    require_nodejs_auto_instrumentation_agent: [:0]u8,
) ?[:0]u8 {
    if (original_value_optional) |original_value| {
        if (std.mem.indexOf(u8, original_value, require_nodejs_auto_instrumentation_agent)) |_| {
            // If the correct "--require ..." flag is already present in NODE_OPTIONS, do nothing. This is particularly
            // important to avoid double injection, for example if we are injecting into a container which has a shell
            // executable as its entry point (into which we inject env var modifications), and then this shell starts
            // the Node.js executable as a child process, which inherits the environment from the already injected
            // shell.
            gpa.free(require_nodejs_auto_instrumentation_agent);
            return null;
        }

        // If NODE_OPTIONS is already set, prepend the "--require ..." flag to the original value.
        // Since we copy over require_nodejs_auto_instrumentation_agent into newly allocated memory, we can free the
        // parameter here.
        defer gpa.free(require_nodejs_auto_instrumentation_agent);
        return std.fmt.allocPrintSentinel(
            gpa,
            "{s} {s}",
            .{ require_nodejs_auto_instrumentation_agent, original_value },
            0,
        ) catch |err| {
            print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ node_options_env_var_name, err });
            return null;
        };
    }

    // If NODE_OPTIONS is not set, simply return the "--require ..." flag.
    return require_nodejs_auto_instrumentation_agent[0..];
}

test "getModifiedNodeOptionsValue: should return --require if original value is unset" {
    const require_nodejs_auto_instrumentation_agent = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "--require /usr/lib/opentelemetry/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/build/src/register.js",
        .{},
        0,
    );
    const modified_node_options_value =
        getModifiedNodeOptionsValue(
            testing.allocator,
            null,
            require_nodejs_auto_instrumentation_agent,
        );
    defer (if (modified_node_options_value) |val| {
        testing.allocator.free(val);
    });
    try testing.expectEqualStrings(
        "--require /usr/lib/opentelemetry/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/build/src/register.js",
        modified_node_options_value orelse "-",
    );
}

test "getModifiedNodeOptionsValue: should prepend --require if original value exists" {
    const original_value: [:0]const u8 = "--abort-on-uncaught-exception"[0.. :0];
    const require_nodejs_auto_instrumentation_agent = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "--require /usr/lib/opentelemetry/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/build/src/register.js",
        .{},
        0,
    );
    const modified_node_options_value =
        getModifiedNodeOptionsValue(
            testing.allocator,
            original_value,
            require_nodejs_auto_instrumentation_agent,
        );
    defer (if (modified_node_options_value) |val| {
        testing.allocator.free(val);
    });
    try testing.expectEqualStrings(
        "--require /usr/lib/opentelemetry/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/build/src/register.js --abort-on-uncaught-exception",
        modified_node_options_value orelse "-",
    );
}

test "getModifiedNodeOptionsValue: should do nothing if our --require is already present" {
    const original_value: [:0]const u8 = "--abort-on-uncaught-exception --require /usr/lib/opentelemetry/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/build/src/register.js --something-else"[0.. :0];
    const require_nodejs_auto_instrumentation_agent = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "--require /usr/lib/opentelemetry/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/build/src/register.js",
        .{},
        0,
    );
    const modified_node_options_value =
        getModifiedNodeOptionsValue(
            testing.allocator,
            original_value,
            require_nodejs_auto_instrumentation_agent,
        );
    try test_util.expectWithMessage(modified_node_options_value == null, "modified_node_options_value == null");
}
