// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const alloc = @import("allocator.zig");
const config = @import("config.zig");
const print = @import("print.zig");
const types = @import("types.zig");
const test_util = @import("test_util.zig");

const testing = std.testing;

pub const node_options_env_var_name = "NODE_OPTIONS";

pub fn checkNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
    original_value_optional: ?[:0]const u8,
    configuration: config.InjectorConfiguration,
) ?types.NullTerminatedString {
    return doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
        original_value_optional,
        configuration.nodejs_auto_instrumentation_agent_path,
    );
}

fn doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
    original_value_optional: ?[:0]const u8,
    nodejs_auto_instrumentation_agent_path: []u8,
) ?types.NullTerminatedString {
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
    const require_nodejs_auto_instrumentation_agent = std.fmt.allocPrintSentinel(alloc.page_allocator, "--require {s}", .{nodejs_auto_instrumentation_agent_path}, 0) catch |err| {
        print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ node_options_env_var_name, err });
        return null;
    };
    return getModifiedNodeOptionsValue(
        original_value_optional,
        require_nodejs_auto_instrumentation_agent,
    );
}

test "doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue: should return null if the Node.js OTel auto instrumentation agent cannot be accessed (no other NODE_OPTIONS are present)" {
    const modifiedNodeOptionsValue =
        doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
            null,
            try std.fmt.allocPrint(test_util.test_allocator, "/invalid/path", .{}),
        );
    try testing.expect(modifiedNodeOptionsValue == null);
}

test "doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue: should return null if the Node.js OTel auto instrumentation agent cannot be accessed (other NODE_OPTIONS are present)" {
    const modifiedNodeOptionsValue =
        doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
            "--abort-on-uncaught-exception"[0.. :0],
            try std.fmt.allocPrint(test_util.test_allocator, "/invalid/path", .{}),
        );
    try testing.expect(modifiedNodeOptionsValue == null);
}

fn getModifiedNodeOptionsValue(original_value_optional: ?[:0]const u8, require_nodejs_auto_instrumentation_agent: types.NullTerminatedString) ?types.NullTerminatedString {
    if (original_value_optional) |original_value| {
        if (std.mem.indexOf(u8, original_value, std.mem.span(require_nodejs_auto_instrumentation_agent))) |_| {
            // If the correct "--require ..." flag is already present in NODE_OPTIONS, do nothing. This is particularly
            // important to avoid double injection, for example if we are injecting into a container which has a shell
            // executable as its entry point (into which we inject env var modifications), and then this shell starts
            // the Node.js executable as a child process, which inherits the environment from the already injected
            // shell.
            return null;
        }

        // If NODE_OPTIONS is already set, prepend the "--require ..." flag to the original value.
        // Note: We must never free the return_buffer, or we may cause a USE_AFTER_FREE memory corruption in the
        // parent process.
        const return_buffer = std.fmt.allocPrintSentinel(
            alloc.page_allocator,
            "{s} {s}",
            .{ require_nodejs_auto_instrumentation_agent, original_value },
            0,
        ) catch |err| {
            print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ node_options_env_var_name, err });
            return null;
        };
        return return_buffer.ptr;
    }

    // If NODE_OPTIONS is not set, simply return the "--require ..." flag.
    return require_nodejs_auto_instrumentation_agent[0..];
}

test "getModifiedNodeOptionsValue: should return --require if original value is unset" {
    const modifiedNodeOptionsValue =
        getModifiedNodeOptionsValue(
            null,
            "--require /__otel_auto_instrumentation/node_js/node_modules/@opentelemetry-js/otel/instrument",
        );
    try testing.expectEqualStrings(
        "--require /__otel_auto_instrumentation/node_js/node_modules/@opentelemetry-js/otel/instrument",
        std.mem.span(modifiedNodeOptionsValue orelse "-"),
    );
}

test "getModifiedNodeOptionsValue: should prepend --require if original value exists" {
    const original_value: [:0]const u8 = "--abort-on-uncaught-exception"[0.. :0];
    const modified_node_options_value =
        getModifiedNodeOptionsValue(
            original_value,
            "--require /__otel_auto_instrumentation/node_js/node_modules/@opentelemetry-js/otel/instrument",
        );
    try testing.expectEqualStrings(
        "--require /__otel_auto_instrumentation/node_js/node_modules/@opentelemetry-js/otel/instrument --abort-on-uncaught-exception",
        std.mem.span(modified_node_options_value orelse "-"),
    );
}

test "getModifiedNodeOptionsValue: should do nothing if our --require is already present" {
    const modifiedNodeOptionsValue = getModifiedNodeOptionsValue("--abort-on-uncaught-exception --require /__otel_auto_instrumentation/node_js/node_modules/@opentelemetry-js/otel/instrument --something-else"[0.. :0], "--require /__otel_auto_instrumentation/node_js/node_modules/@opentelemetry-js/otel/instrument");
    try test_util.expectWithMessage(modifiedNodeOptionsValue == null, "modifiedNodeOptionsValue == null");
}
