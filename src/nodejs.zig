// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const config = @import("config.zig");
const js_runtime = @import("js_runtime.zig");
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
    io: std.Io,
    gpa: std.mem.Allocator,
    original_value_optional: ?[:0]const u8,
    configuration: config.InjectorConfiguration,
) ?[:0]u8 {
    return doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
        io,
        gpa,
        original_value_optional,
        configuration.nodejs_auto_instrumentation_agent_path,
        configuration.auto_instrumentation_disabled.nodejs,
        js_runtime.detect, // Passed in for testing reasons.
    );
}

fn doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
    io: std.Io,
    gpa: std.mem.Allocator,
    original_value_optional: ?[:0]const u8,
    nodejs_auto_instrumentation_agent_path: []u8,
    nodejs_instrumentation_disabled: bool,
    comptime detect_js_runtime: fn () js_runtime.JsRuntime,
) ?[:0]u8 {
    if (nodejs_instrumentation_disabled or nodejs_auto_instrumentation_agent_path.len == 0) {
        print.printInfo("Skipping the injection of the Node.js OpenTelemetry auto-instrumentation because it has been explicitly disabled.", .{});
        return null;
    }

    if (detect_js_runtime() != .nodejs) {
        print.printDebug("Skipping the injection of the Node.js OpenTelemetry auto-instrumentation because this process is not a Node.js process.", .{});
        // A process that is not Node.js can still inherit NODE_OPTIONS with the --require flag from a Node.js parent
        // process, for example Deno started from an npm script. Runtimes like Deno read NODE_OPTIONS as well and fail
        // to start when they cannot load the module, so remove the flag. Node.js processes started by this process get
        // it again from the injector running in them.
        return removeInheritedRequireFlag(gpa, original_value_optional, nodejs_auto_instrumentation_agent_path);
    }

    // Check the existence of the Node module: requiring or importing a module
    // that does not exist or cannot be opened will crash the Node.js process
    // with an 'ERR_MODULE_NOT_FOUND' error.
    std.Io.Dir.cwd().access(io, nodejs_auto_instrumentation_agent_path, .{}) catch |err| {
        print.printError("Skipping the injection of the Node.js OpenTelemetry auto-instrumentation in \"{s}\" because of an issue accessing the Node.js module at \"{s}\": {}", .{ node_options_env_var_name, nodejs_auto_instrumentation_agent_path, err });
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

test "doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue: should return null if nodejs_instrumentation_disabled is true" {
    const path = try std.fmt.allocPrint(testing.allocator, "/some/valid/path", .{});
    defer testing.allocator.free(path);
    const modified_node_options_value =
        doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
            testing.io,
            testing.allocator,
            null,
            path,
            true,
            detectNodeJs,
        );
    try test_util.expectWithMessage(modified_node_options_value == null, "modified_node_options_value == null");
}

test "doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue: should return null if nodejs_auto_instrumentation_agent_path is the empty string" {
    const path = try std.fmt.allocPrint(testing.allocator, "", .{});
    defer testing.allocator.free(path);
    const modified_node_options_value =
        doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
            testing.io,
            testing.allocator,
            null,
            path,
            false,
            detectNodeJs,
        );
    try test_util.expectWithMessage(modified_node_options_value == null, "modified_node_options_value == null");
}

test "doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue: should return null if the Node.js OTel auto-instrumentation agent cannot be accessed (no other NODE_OPTIONS are present)" {
    const path = try std.fmt.allocPrint(testing.allocator, "/invalid/path", .{});
    defer testing.allocator.free(path);
    const modified_node_options_value =
        doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
            testing.io,
            testing.allocator,
            null,
            path,
            false,
            detectNodeJs,
        );
    try test_util.expectWithMessage(modified_node_options_value == null, "modified_node_options_value == null");
}

test "doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue: should return null if the Node.js OTel auto-instrumentation agent cannot be accessed (other NODE_OPTIONS are present)" {
    const path = try std.fmt.allocPrint(testing.allocator, "/invalid/path", .{});
    defer testing.allocator.free(path);
    const modified_node_options_value =
        doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
            testing.io,
            testing.allocator,
            "--abort-on-uncaught-exception"[0.. :0],
            path,
            false,
            detectNodeJs,
        );
    try test_util.expectWithMessage(modified_node_options_value == null, "modified_node_options_value == null");
}

test "doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue: should remove an inherited --require in a process that is not Node.js" {
    var path_buffer = "/agent/register.js".*;
    const modified_node_options_value =
        doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
            testing.io,
            testing.allocator,
            "--require /agent/register.js --no-deprecation"[0.. :0],
            &path_buffer,
            false,
            detectUnknownRuntime,
        ) orelse return error.ExpectedModifiedValue;
    defer testing.allocator.free(modified_node_options_value);
    try testing.expectEqualStrings("--no-deprecation", modified_node_options_value);
}

fn detectNodeJs() js_runtime.JsRuntime {
    return .nodejs;
}

fn detectUnknownRuntime() js_runtime.JsRuntime {
    return .unknown;
}

test "doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue: should add --require for a Node.js process" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "register.js", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "register.js", testing.allocator);
    defer testing.allocator.free(path);
    const modified_node_options_value =
        doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
            testing.io,
            testing.allocator,
            "--no-deprecation"[0.. :0],
            path,
            false,
            detectNodeJs,
        ) orelse return error.ExpectedModifiedValue;
    defer testing.allocator.free(modified_node_options_value);
    const expected = try std.fmt.allocPrint(testing.allocator, "--require {s} --no-deprecation", .{path});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, modified_node_options_value);
}

test "doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue: should return null for a process that is not Node.js" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "register.js", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "register.js", testing.allocator);
    defer testing.allocator.free(path);
    const modified_node_options_value =
        doCheckNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
            testing.io,
            testing.allocator,
            "--no-deprecation"[0.. :0],
            path,
            false,
            detectUnknownRuntime,
        );
    try test_util.expectWithMessage(modified_node_options_value == null, "modified_node_options_value == null");
}

/// Returns the value of NODE_OPTIONS without the "--require <agent path>" flag the injector adds, or null if the value
/// does not contain the flag. Every occurrence of the exact flag is removed, as a whole space-separated token, together
/// with one adjacent space; everything else in the value is kept as it is. If the value only consists of the flag, the
/// result is the empty string, which Node.js and other runtimes treat like an unset NODE_OPTIONS.
fn removeInheritedRequireFlag(
    gpa: std.mem.Allocator,
    original_value_optional: ?[:0]const u8,
    nodejs_auto_instrumentation_agent_path: []const u8,
) ?[:0]u8 {
    const original_value = original_value_optional orelse return null;
    const require_flag = std.fmt.allocPrint(gpa, "--require {s}", .{nodejs_auto_instrumentation_agent_path}) catch |err| {
        print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ node_options_env_var_name, err });
        return null;
    };
    defer gpa.free(require_flag);

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(gpa);
    var removed_any = false;
    // The part of original_value before copy_start has been copied to result or has been removed.
    var copy_start: usize = 0;
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, original_value, search_start, require_flag)) |flag_start| {
        const flag_end = flag_start + require_flag.len;
        const starts_token = flag_start == 0 or original_value[flag_start - 1] == ' ';
        const ends_token = flag_end == original_value.len or original_value[flag_end] == ' ';
        if (!starts_token or !ends_token) {
            search_start = flag_start + 1;
            continue;
        }
        result.appendSlice(gpa, original_value[copy_start..flag_start]) catch |err| {
            print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ node_options_env_var_name, err });
            return null;
        };
        // Remove one adjacent space, preferably the one after the flag, since the injector prepends the flag. If the
        // flag is at the end of the value, remove the space before it, which has already been copied to result.
        if (flag_end < original_value.len) {
            copy_start = flag_end + 1;
        } else {
            copy_start = flag_end;
            if (result.items.len > 0 and result.items[result.items.len - 1] == ' ') {
                result.items.len -= 1;
            }
        }
        search_start = copy_start;
        removed_any = true;
    }
    if (!removed_any) {
        return null;
    }

    print.printDebug("Removing the inherited \"{s}\" from \"{s}\" because this process is not a Node.js process.", .{ require_flag, node_options_env_var_name });
    result.appendSlice(gpa, original_value[copy_start..]) catch |err| {
        print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ node_options_env_var_name, err });
        return null;
    };
    return gpa.dupeSentinel(u8, result.items, 0) catch |err| {
        print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ node_options_env_var_name, err });
        return null;
    };
}

test "removeInheritedRequireFlag: removes the injector's --require flag" {
    const cases = [_]struct { original: [:0]const u8, expected: ?[]const u8 }{
        .{ .original = "--require /agent/register.js", .expected = "" },
        .{ .original = "--require /agent/register.js --no-deprecation", .expected = "--no-deprecation" },
        .{ .original = "--no-deprecation --require /agent/register.js", .expected = "--no-deprecation" },
        .{ .original = "--a --require /agent/register.js --b", .expected = "--a --b" },
        // Not the injector's flag, or not as a whole token.
        .{ .original = "--no-deprecation", .expected = null },
        .{ .original = "--require /agent/register.js.bak", .expected = null },
        .{ .original = "--require /other/register.js", .expected = null },
        .{ .original = "x--require /agent/register.js", .expected = null },
        // A partial match before the real token.
        .{ .original = "--require /agent/register.jsx --require /agent/register.js", .expected = "--require /agent/register.jsx" },
        // The empty value, and a value that only contains spaces.
        .{ .original = "", .expected = null },
        .{ .original = " ", .expected = null },
        // Every occurrence of the flag is removed.
        .{ .original = "--require /agent/register.js --require /agent/register.js", .expected = "" },
        .{ .original = "--require /agent/register.js --a --require /agent/register.js", .expected = "--a" },
        .{ .original = "--a --require /agent/register.js --require /agent/register.js", .expected = "--a" },
        .{ .original = "--a --require /agent/register.js --b --require /agent/register.js --c", .expected = "--a --b --c" },
        .{ .original = "--require /agent/register.js --require /other/register.js --require /agent/register.js", .expected = "--require /other/register.js" },
        // Other whitespace in the value is kept as it is.
        .{ .original = "--a  --require /agent/register.js  --b", .expected = "--a   --b" },
        .{ .original = " --require /agent/register.js", .expected = "" },
        .{ .original = "--require /agent/register.js ", .expected = "" },
        // A tab is not a token boundary, like the flag the injector adds, which always uses a space.
        .{ .original = "--a\t--require /agent/register.js", .expected = null },
        // The --require=<path> and -r <path> forms are not the flag the injector adds.
        .{ .original = "--require=/agent/register.js", .expected = null },
        .{ .original = "-r /agent/register.js", .expected = null },
        // A quoted value that contains the flag is a different token.
        .{ .original = "--title=\"--require /agent/register.js\"", .expected = null },
    };
    for (cases) |case| {
        const result = removeInheritedRequireFlag(testing.allocator, case.original, "/agent/register.js");
        defer if (result) |r| testing.allocator.free(r);
        if (case.expected) |expected| {
            try testing.expectEqualStrings(expected, result orelse return error.ExpectedModifiedValue);
        } else {
            try testing.expect(result == null);
        }
    }
    try testing.expect(removeInheritedRequireFlag(testing.allocator, null, "/agent/register.js") == null);
}

fn getModifiedNodeOptionsValue(
    gpa: std.mem.Allocator,
    original_value_optional: ?[:0]const u8,
    require_nodejs_auto_instrumentation_agent: [:0]u8,
) ?[:0]u8 {
    // An empty NODE_OPTIONS (for example after a parent process that is not Node.js has removed the inherited
    // "--require ..." flag) is treated like an unset one, to not add a trailing space.
    if (original_value_optional != null and original_value_optional.?.len > 0) {
        const original_value = original_value_optional.?;
        if (std.mem.indexOf(u8, original_value, require_nodejs_auto_instrumentation_agent)) |_| {
            // If the correct "--require ..." flag is already present in NODE_OPTIONS, do nothing. This is particularly
            // important to avoid double injection, for example if a Node.js process starts another Node.js process as
            // a child process, which inherits the environment from the already injected parent process.
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
        "--require /usr/lib/opentelemetry/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/dist/register.cjs",
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
        "--require /usr/lib/opentelemetry/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/dist/register.cjs",
        modified_node_options_value orelse "-",
    );
}

test "getModifiedNodeOptionsValue: should return --require if original value is the empty string" {
    const require_nodejs_auto_instrumentation_agent = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "--require /agent/register.js",
        .{},
        0,
    );
    const modified_node_options_value =
        getModifiedNodeOptionsValue(
            testing.allocator,
            ""[0.. :0],
            require_nodejs_auto_instrumentation_agent,
        );
    defer (if (modified_node_options_value) |val| {
        testing.allocator.free(val);
    });
    try testing.expectEqualStrings("--require /agent/register.js", modified_node_options_value orelse "-");
}

test "getModifiedNodeOptionsValue: should prepend --require if original value exists" {
    const original_value: [:0]const u8 = "--abort-on-uncaught-exception"[0.. :0];
    const require_nodejs_auto_instrumentation_agent = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "--require /usr/lib/opentelemetry/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/dist/register.cjs",
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
        "--require /usr/lib/opentelemetry/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/dist/register.cjs --abort-on-uncaught-exception",
        modified_node_options_value orelse "-",
    );
}

test "getModifiedNodeOptionsValue: should do nothing if our --require is already present" {
    const original_value: [:0]const u8 = "--abort-on-uncaught-exception --require /usr/lib/opentelemetry/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/dist/register.cjs --something-else"[0.. :0];
    const require_nodejs_auto_instrumentation_agent = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "--require /usr/lib/opentelemetry/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/dist/register.cjs",
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
