// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const config = @import("config.zig");
const dotnet = @import("dotnet.zig");
const jvm = @import("jvm.zig");
const node_js = @import("node_js.zig");
const print = @import("print.zig");
const res_attrs = @import("resource_attributes.zig");
const types = @import("types.zig");
const pattern_matcher = @import("patterns_matcher.zig");
const args_parser = @import("args_parser.zig");

const assert = std.debug.assert;
const testing = std.testing;
const expect = testing.expect;

// We need to use a rather "innocent" type here, the actual type involves
// optionals that cannot be used in global declarations.
extern var __environ: [*]u8;

// Ensure we process requests synchronously. LibC is *not* threadsafe
// with respect to the environment, but chances are some apps will try
// to look up env vars in parallel
const _env_mutex = std.Thread.Mutex{};

// Keep global pointers to already-calculated values to avoid multiple allocations
// on repeated lookups.
var modified_java_tool_options_value_calculated = false;
var modified_java_tool_options_value: ?types.NullTerminatedString = null;
var modified_node_options_value_calculated = false;
var modified_node_options_value: ?types.NullTerminatedString = null;
var modified_otel_resource_attributes_value_calculated = false;
var modified_otel_resource_attributes_value: ?types.NullTerminatedString = null;

export fn getenv(name_z: types.NullTerminatedString) ?types.NullTerminatedString {
    const name = std.mem.sliceTo(name_z, 0);

    // Need to change type from `const` to be able to lock
    var env_mutex = _env_mutex;
    env_mutex.lock();
    defer env_mutex.unlock();

    // Dynamic libs do not get the std.os.environ initialized, see https://github.com/ziglang/zig/issues/4524, so we
    // back fill it. This logic is based on parsing of envp on zig's start. We re-bind the environment every time, as we
    // cannot ensure it did not change since the previous invocation. Libc implementations can re-allocate the
    // environment (http://github.com/lattera/glibc/blob/master/stdlib/setenv.c;
    // https://git.musl-libc.org/cgit/musl/tree/src/env/setenv.c) if the backing memory location is outgrown by apps
    // modifying the environment via setenv or putenv.
    const environment_optional: [*:null]?[*:0]u8 = @ptrCast(@alignCast(__environ));
    var environment_count: usize = 0;
    if (@intFromPtr(__environ) != 0) { // __environ can be a null pointer, e.g. directly after clearenv()
        while (environment_optional[environment_count]) |_| : (environment_count += 1) {}
    }
    std.os.environ = @as([*][*:0]u8, @ptrCast(environment_optional))[0..environment_count];

    print.initDebugFlag();
    print.printDebug("getenv({s}) called", .{name});

    const configuration = config.readConfiguration();

    const res = getEnvValue(name, configuration);

    if (res) |value| {
        print.printDebug("getenv({s}) -> \"{s}\"", .{ name, value });
    } else {
        print.printDebug("getenv({s}) -> null", .{name});
    }

    return res;
}

fn getEnvValue(name: [:0]const u8, configuration: config.InjectorConfiguration) ?types.NullTerminatedString {
    const original_value = std.posix.getenv(name);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get the program full executable path
    const exe_path = std.fs.selfExePathAlloc(allocator) catch |err| {
        print.printDebug("failed to get executable path: {any}", .{err});
        if (original_value) |val| {
            return val.ptr;
        }
        return null;
    };
    defer allocator.free(exe_path);
    print.printDebug("executable: {s}", .{exe_path});

    // Get all command line arguments from the process information, std.process.argsAlloc returns empty list and so
    // does std.os.argv.
    const args = args_parser.cmdLineForPID(allocator, std.os.linux.getpid()) catch |err| {
        print.printDebug("failed to get executable arguments: {any}", .{err});
        if (original_value) |val| {
            return val.ptr;
        }
        return null;
    };

    defer {
        for (args) |arg| {
            allocator.free(arg);
        }
        allocator.free(args);
    }

    if (print.isDebug()) {
        for (args, 0..) |arg, i| {
            print.printDebug("Arg[{d}]: {s}", .{ i, arg });
        }
    }

    var allow = (configuration.include_paths.len == 0) or pattern_matcher.matchesAnyPattern(exe_path, configuration.include_paths);
    allow = allow or (configuration.include_args.len == 0) or pattern_matcher.matchesManyAnyPattern(args, configuration.include_args);
    var deny = (configuration.exclude_paths.len > 0) and pattern_matcher.matchesAnyPattern(exe_path, configuration.exclude_paths);
    deny = deny or ((configuration.exclude_args.len > 0) and pattern_matcher.matchesManyAnyPattern(args, configuration.exclude_args));

    if (!allow or deny) {
        print.printDebug("executable with path {s} ignored. allow={any}, deny={any}", .{ exe_path, allow, deny });
        if (print.isDebug()) {
            if (configuration.include_paths.len > 0) {
                print.printDebug("  include_paths:", .{});
                for (configuration.include_paths) |pattern| {
                    print.printDebug("    - {s}", .{pattern});
                }
            }
            if (configuration.include_args.len > 0) {
                print.printDebug("  include_arguments:", .{});
                for (configuration.include_args) |pattern| {
                    print.printDebug("    - {s}", .{pattern});
                }
            }
            if (configuration.exclude_paths.len > 0) {
                print.printDebug("  exclude_paths:", .{});
                for (configuration.exclude_paths) |pattern| {
                    print.printDebug("    - {s}", .{pattern});
                }
            }
            if (configuration.exclude_args.len > 0) {
                print.printDebug("  exclude_arguments:", .{});
                for (configuration.exclude_args) |pattern| {
                    print.printDebug("    - {s}", .{pattern});
                }
            }
        }
        if (original_value) |val| {
            return val.ptr;
        }
        return null;
    }

    if (std.mem.eql(
        u8,
        name,
        res_attrs.otel_resource_attributes_env_var_name,
    )) {
        if (!modified_otel_resource_attributes_value_calculated) {
            modified_otel_resource_attributes_value = res_attrs.getModifiedOtelResourceAttributesValue(original_value);
            modified_otel_resource_attributes_value_calculated = true;
        }
        if (modified_otel_resource_attributes_value) |updated_value| {
            return updated_value;
        }
    } else if (std.mem.eql(u8, name, jvm.java_tool_options_env_var_name)) {
        if (!modified_java_tool_options_value_calculated) {
            modified_java_tool_options_value =
                jvm.checkOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue(original_value, configuration);
            modified_java_tool_options_value_calculated = true;
        }
        if (modified_java_tool_options_value) |updated_value| {
            return updated_value;
        }
    } else if (std.mem.eql(u8, name, node_js.node_options_env_var_name)) {
        if (!modified_node_options_value_calculated) {
            modified_node_options_value =
                node_js.checkNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
                    original_value,
                    configuration,
                );
            modified_node_options_value_calculated = true;
        }
        if (modified_node_options_value) |updated_value| {
            return updated_value;
        }
    } else if (std.mem.eql(u8, name, "CORECLR_ENABLE_PROFILING")) {
        if (dotnet.getDotnetValues(configuration)) |v| {
            return v.coreclr_enable_profiling;
        }
    } else if (std.mem.eql(u8, name, "CORECLR_PROFILER")) {
        if (dotnet.getDotnetValues(configuration)) |v| {
            return v.coreclr_profiler;
        }
    } else if (std.mem.eql(u8, name, "CORECLR_PROFILER_PATH")) {
        if (dotnet.getDotnetValues(configuration)) |v| {
            return v.coreclr_profiler_path;
        }
    } else if (std.mem.eql(u8, name, "DOTNET_ADDITIONAL_DEPS")) {
        if (dotnet.getDotnetValues(configuration)) |v| {
            return v.additional_deps;
        }
    } else if (std.mem.eql(u8, name, "DOTNET_SHARED_STORE")) {
        if (dotnet.getDotnetValues(configuration)) |v| {
            return v.shared_store;
        }
    } else if (std.mem.eql(u8, name, "DOTNET_STARTUP_HOOKS")) {
        if (dotnet.getDotnetValues(configuration)) |v| {
            return v.startup_hooks;
        }
    } else if (std.mem.eql(u8, name, "OTEL_DOTNET_AUTO_HOME")) {
        if (dotnet.getDotnetValues(configuration)) |v| {
            return v.otel_auto_home;
        }
    }

    // The requested environment variable is not one that we want to modify, hence we just return the original value by
    // returning a pointer to it.
    if (original_value) |val| {
        return val.ptr;
    }

    // The requested environment variable is not one that we want to modify, and it does not exist. Return null.
    return null;
}
