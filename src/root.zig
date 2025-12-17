// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const builtin = @import("builtin");
const std = @import("std");

const alloc = @import("allocator.zig");
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

var custom_env_vars_are_injected = false;

// Cache for executable path and command line arguments (processed once)
var cached_executable_path_calculated = false;
var cached_executable_path: []u8 = &[_]u8{};
var cached_cmdline_args_calculated = false;
var cached_cmdline_args: []const []const u8 = &[_][]const u8{};

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
    const environment_count = countEnvironmentVariables(environment_optional);
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
    if (!custom_env_vars_are_injected) {
        if (setCustomEnvVariables(configuration.all_auto_instrumentation_agents_env_vars)) {
            custom_env_vars_are_injected = true;
        } else {
            print.printError("failed to set environment variables from configuration", .{});
        }
    }

    const original_value = std.posix.getenv(name);

    const exe_path = getExecutablePath();
    const args = getCommandLineArgs();

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

fn setCustomEnvVariables(custom_env_vars: std.StringHashMap([]u8)) bool {
    if (custom_env_vars.count() == 0) {
        return true;
    }

    const environment_optional: [*:null]?[*:0]u8 = @ptrCast(@alignCast(__environ));
    const environment_count = countEnvironmentVariables(environment_optional);

    var vars_to_update_count: usize = 0;
    for (0..environment_count) |i| {
        if (environment_optional[i]) |env_entry| {
            const slice = std.mem.sliceTo(env_entry, 0);
            if (std.mem.indexOfScalar(u8, slice, '=')) |equals_idx| {
                const entry_name = slice[0..equals_idx];
                if (custom_env_vars.contains(entry_name)) {
                    vars_to_update_count += 1;
                }
            }
        }
    }

    const new_size = environment_count + (custom_env_vars.count() - vars_to_update_count) + 1;
    const new_environment = alloc.page_allocator.allocSentinel(?[*:0]u8, new_size, null) catch {
        print.printError("failed to allocate memory for environment array", .{});
        return false;
    };

    for (0..environment_count) |i| {
        new_environment[i] = environment_optional[i];
    }

    var updated_vars = std.StringHashMap(bool).init(alloc.page_allocator);
    defer updated_vars.deinit();

    // Update existing variables
    for (0..environment_count) |i| {
        const raw_env_var = std.mem.sliceTo(new_environment[i].?, 0);
        if (std.mem.indexOfScalar(u8, raw_env_var, '=')) |equalsIdx| {
            const name = raw_env_var[0..equalsIdx];
            if (custom_env_vars.get(name)) |value| {
                new_environment[i] = formatEnvVar(name, value) catch {
                    print.printError("failed to format environment variable {s}", .{name});
                    return false;
                };
                updated_vars.put(name, true) catch {
                    print.printError("failed to track updated variable {s}", .{name});
                    return false;
                };
                print.printDebug("updated environment variable {s}={s}", .{ name, value });
            }
        }
    }

    // Append new variables
    var new_var_index = environment_count;
    var env_var_iterator = custom_env_vars.iterator();
    while (env_var_iterator.next()) |env_var| {
        const name = env_var.key_ptr.*;

        if (!updated_vars.contains(name)) {
            const value = std.mem.sliceTo(env_var.value_ptr.*, 0);
            const env_string = formatEnvVar(name, value) catch {
                print.printError("failed to format environment variable {s}", .{name});
                return false;
            };
            new_environment[new_var_index] = env_string;
            new_var_index += 1;
            print.printDebug("added environment variable {s}={s}", .{ name, value });
        }
    }

    // Add null terminator in the end
    new_environment[new_var_index] = null;

    const new_environ_ptr: [*]u8 = @ptrCast(new_environment.ptr);
    __environ = new_environ_ptr;
    std.os.environ = @as([*][*:0]u8, @ptrCast(new_environment))[0..new_var_index];

    return true;
}

fn formatEnvVar(name: []const u8, value: []const u8) std.mem.Allocator.Error![:0]u8 {
    return std.fmt.allocPrintSentinel(alloc.page_allocator, "{s}={s}", .{ name, value }, 0);
}

fn countEnvironmentVariables(environment: [*:null]?[*:0]u8) usize {
    var count: usize = 0;
    if (@intFromPtr(__environ) != 0) { // __environ can be a null pointer, e.g. directly after clearenv()
        while (environment[count]) |_| : (count += 1) {}
    }
    return count;
}

fn getCommandLineArgs() []const []const u8 {
    // Get command line arguments (cached after first read)
    // Dynamically injected libraries don't get std.process.argsAlloc populated and
    // neither does std.os.argv. We read using the /proc/{pid}/cmdline.
    if (!cached_cmdline_args_calculated) {
        cached_cmdline_args = args_parser.cmdLineForPID(alloc.page_allocator) catch |err| {
            print.printDebug("failed to get executable arguments: {any}", .{err});
            cached_cmdline_args = &[_][]const u8{};
            cached_cmdline_args_calculated = true;
            return cached_cmdline_args;
        };
        cached_cmdline_args_calculated = true;

        if (print.isDebug()) {
            for (cached_cmdline_args, 0..) |arg, i| {
                print.printDebug("arg[{d}]: {s}", .{ i, arg });
            }
        }
    }

    return cached_cmdline_args;
}

fn getExecutablePath() []u8 {
    if (!cached_executable_path_calculated) {
        // Get the program full executable path
        cached_executable_path = std.fs.selfExePathAlloc(alloc.page_allocator) catch |err| {
            print.printDebug("failed to get executable path: {any}", .{err});
            cached_executable_path_calculated = true;
            cached_executable_path = &[_]u8{};
            return cached_executable_path;
        };

        cached_executable_path_calculated = true;
        print.printDebug("executable: {s}", .{cached_executable_path});
    }

    return cached_executable_path;
}
