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
const injection_happened_msg = "injecting the Node.js OpenTelemetry auto instrumentation agent";

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
        print.printMessage("Skipping the injection of the Node.js OpenTelemetry auto instrumentation because it has been explicitly disabled.", .{});
        if (original_value_optional) |original_value| {
            return original_value;
        }
        return null;
    }

    // Check the existence of the Node module: requiring or importing a module
    // that does not exist or cannot be opened will crash the Node.js process
    // with an 'ERR_MODULE_NOT_FOUND' error.
    std.fs.cwd().access(nodejs_auto_instrumentation_agent_path, .{}) catch |err| {
        print.printError("Skipping the injection of the Node.js OpenTelemetry auto instrumentation in \"{s}\" because of an issue accessing the Node.js module at \"{s}\": {}", .{ node_options_env_var_name, nodejs_auto_instrumentation_agent_path, err });
        if (original_value_optional) |original_value| {
            return original_value;
        }
        return null;
    };
    const require_nodejs_auto_instrumentation_agent = std.fmt.allocPrintSentinel(alloc.page_allocator, "--require {s}", .{nodejs_auto_instrumentation_agent_path}, 0) catch |err| {
        print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ node_options_env_var_name, err });
        if (original_value_optional) |original_value| {
            return original_value;
        }
        return null;
    };
    return getModifiedNodeOptionsValue(
        original_value_optional,
        require_nodejs_auto_instrumentation_agent,
    );
}

test "doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue: should return null if the Node.js OTel auto instrumentation agent cannot be accessed" {
    const modifiedNodeOptionsValue =
        doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
            null,
            try std.fmt.allocPrint(test_util.test_allocator, "/invalid/path", .{}),
        );
    try testing.expect(modifiedNodeOptionsValue == null);
}

test "doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue: should return the original value if the Node.js OTel auto instrumentation agent cannot be accessed" {
    const modifiedNodeOptionsValue =
        doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
            "--abort-on-uncaught-exception"[0.. :0],
            try std.fmt.allocPrint(test_util.test_allocator, "/invalid/path", .{}),
        );
    try testing.expectEqualStrings(
        "--abort-on-uncaught-exception",
        std.mem.span(modifiedNodeOptionsValue orelse "-"),
    );
}

fn getModifiedNodeOptionsValue(original_value_optional: ?[:0]const u8, require_nodejs_auto_instrumentation_agent: types.NullTerminatedString) ?types.NullTerminatedString {
    if (original_value_optional) |original_value| {
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
            return original_value;
        };

        print.printMessage(injection_happened_msg, .{});
        return return_buffer.ptr;
    }

    // If NODE_OPTIONS is not set, simply return the "--require ..." flag.
    print.printMessage(injection_happened_msg, .{});
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
