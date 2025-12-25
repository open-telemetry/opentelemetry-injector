// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const builtin = @import("builtin");
const std = @import("std");

const config = @import("config.zig");
const dotnet = @import("dotnet.zig");
const libc = @import("libc.zig");
const jvm = @import("jvm.zig");
const node_js = @import("node_js.zig");
const print = @import("print.zig");
const res_attrs = @import("resource_attributes.zig");
const types = @import("types.zig");
const pattern_matcher = @import("patterns_matcher.zig");
const args_parser = @import("args_parser.zig");

const empty_z_string = "\x00";

const init_section_name = switch (builtin.target.os.tag) {
    .linux => ".init_array",
    .macos => "__DATA,__mod_init_func", // needed to run tests locally on macOS
    else => {
        error.OsNotSupported;
    },
};

export const init_array: [1]*const fn () callconv(.c) void linksection(init_section_name) = .{&initEnviron};

var environ_ptr: ?types.EnvironPtr = null;

const InjectorError = error{
    CannotFindEnvironSymbol,
};

fn initEnviron() callconv(.c) void {
    const allocator = std.heap.page_allocator;

    print.initLogLevelFromProcSelfEnviron() catch |err| {
        // If we fail to read the log level, we continue processing, using the default log level.
        print.printError("failed to read log level from environment: {}", .{err});
        print.printError("using default log level {}", .{print.getLogLevel()});
    };

    const libc_info = libc.getLibCInfo(allocator) catch |err| {
        if (err == error.UnknownLibCFlavor) {
            print.printError("no libc found: {}", .{err});
        } else {
            print.printError("failed to identify libc: {}", .{err});
        }
        return;
    };
    defer allocator.free(libc_info.name);
    print.printDebug("identified {s} libc loaded from {s}", .{ switch (libc_info.flavor) {
        types.LibCFlavor.GNU => "GNU",
        types.LibCFlavor.MUSL => "musl",
        else => "unknown",
    }, libc_info.name });
    dotnet.setLibcFlavor(libc_info.flavor);

    environ_ptr = libc_info.environ_ptr;
    updateStdOsEnviron() catch |err| {
        print.printError("initEnviron(): cannot update std.os.environ: {}; ", .{err});
        return;
    };

    const configuration = config.readConfiguration(allocator);

    if (!evaluateAllowDeny(allocator, configuration)) {
        return;
    }

    const maybe_modified_resource_attributes = res_attrs.getModifiedOtelResourceAttributesValue(
        allocator,
        std.posix.getenv(res_attrs.otel_resource_attributes_env_var_name),
    ) catch |err| {
        print.printError("cannot calculate modified OTEL_RESOURCE_ATTRIBUTES: {}", .{err});
        return;
    };

    if (maybe_modified_resource_attributes) |modified_resource_attributes| {
        // Note: getModifiedOtelResourceAttributesValue returns a sentinel-terminated slices, which can be coerced
        // automatically into the sentinel-terminated many pointer which is required by setenv.
        const setenv_res =
            libc_info.setenv_fn_ptr(
                res_attrs.otel_resource_attributes_env_var_name,
                modified_resource_attributes,
                true,
            );
        if (setenv_res == 0) {
            print.printDebug(
                "setting \"{s}\"=\"{s}\"",
                .{ res_attrs.otel_resource_attributes_env_var_name, modified_resource_attributes },
            );
        } else {
            print.printError(
                "failed to set \"{s}\"=\"{s}\", setenv returned: {d}",
                .{ res_attrs.otel_resource_attributes_env_var_name, modified_resource_attributes, setenv_res },
            );
        }
    }

    modifyEnvironmentVariable(
        allocator,
        libc_info.setenv_fn_ptr,
        node_js.node_options_env_var_name,
        configuration,
    );
    modifyEnvironmentVariable(
        allocator,
        libc_info.setenv_fn_ptr,
        jvm.java_tool_options_env_var_name,
        configuration,
    );
    modifyEnvironmentVariable(
        allocator,
        libc_info.setenv_fn_ptr,
        dotnet.coreclr_enable_profiling_env_var_name,
        configuration,
    );
    modifyEnvironmentVariable(
        allocator,
        libc_info.setenv_fn_ptr,
        dotnet.coreclr_profiler_env_var_name,
        configuration,
    );
    modifyEnvironmentVariable(
        allocator,
        libc_info.setenv_fn_ptr,
        dotnet.coreclr_profiler_path_env_var_name,
        configuration,
    );
    modifyEnvironmentVariable(
        allocator,
        libc_info.setenv_fn_ptr,
        dotnet.dotnet_additional_deps_env_var_name,
        configuration,
    );
    modifyEnvironmentVariable(
        allocator,
        libc_info.setenv_fn_ptr,
        dotnet.dotnet_shared_store_env_var_name,
        configuration,
    );
    modifyEnvironmentVariable(
        allocator,
        libc_info.setenv_fn_ptr,
        dotnet.dotnet_startup_hooks_env_var_name,
        configuration,
    );
    modifyEnvironmentVariable(
        allocator,
        libc_info.setenv_fn_ptr,
        dotnet.otel_dotnet_auto_home_env_var_name,
        configuration,
    );

    setCustomEnvironmentVariables(
        allocator,
        libc_info.setenv_fn_ptr,
        configuration.all_auto_instrumentation_agents_env_vars,
    );

    print.printInfo("environment injection finished", .{});
}

fn updateStdOsEnviron() !void {
    // Dynamic libs do not get the std.os.environ initialized, see https://github.com/ziglang/zig/issues/4524, so we
    // back fill it. This logic is based on parsing of envp on zig's start.
    if (environ_ptr) |environment_ptr| {
        const env_array = environment_ptr.*;
        var env_var_count: usize = 0;
        // Note: env_array will be empty in some cases, for example if the application calls clearenv. Accessing
        // env_array[0] as we do in the while loop below would segfault. Instead we initialize an empty environ slice.
        if (env_array == 0) {
            std.os.environ = &.{};
            return;
        }
        while (env_array[env_var_count] != null) : (env_var_count += 1) {}

        std.os.environ = @ptrCast(@constCast(env_array[0..env_var_count]));
    } else {
        return error.CannotFindEnvironSymbol;
    }
}

fn evaluateAllowDeny(allocator: std.mem.Allocator, configuration: config.InjectorConfiguration) bool {
    const exe_path = getExecutablePath(allocator) catch {
        // Skip allow-deny evaluation if getting the executable path has failed. The error has already been logged in
        // getExecutablePath.
        return true;
    };
    const args = getCommandLineArgs(allocator) catch {
        // Skip allow-deny evaluation if getting the arguments has failed. The error has already been logged in
        // getCommandLineArgs.
        return true;
    };

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
        return false;
    }
    return true;
}

fn getCommandLineArgs(allocator: std.mem.Allocator) ![]const []const u8 {
    // Get command line arguments.
    // Dynamically injected libraries don't get std.process.argsAlloc populated and
    // neither does std.os.argv. We read using the /proc/{pid}/cmdline.
    const cmdline_args = args_parser.cmdLineForPID(allocator) catch |err| {
        print.printDebug("failed to get executable arguments: {any}", .{err});
        return err;
    };

    if (print.isDebug()) {
        for (cmdline_args, 0..) |arg, i| {
            print.printDebug("arg[{d}]: {s}", .{ i, arg });
        }
    }

    return cmdline_args;
}

fn getExecutablePath(allocator: std.mem.Allocator) ![]u8 {
    // Get the program full executable path
    const executable_path = std.fs.selfExePathAlloc(allocator) catch |err| {
        print.printDebug("failed to get executable path: {any}", .{err});
        return err;
    };

    print.printDebug("executable: {s}", .{executable_path});

    return executable_path;
}

fn modifyEnvironmentVariable(
    allocator: std.mem.Allocator,
    setenv_fn_ptr: types.SetenvFnPtr,
    name: [:0]const u8,
    configuration: config.InjectorConfiguration,
) void {
    if (getEnvValue(allocator, name, configuration)) |value| {
        // Note: We must *not* free/deallocate the return value of getEnvValue after handing it over to setenv, or we
        // may cause a USE_AFTER_FREE memory corruption in the parent process.
        // Note: getEnvValue returns a sentinel-terminated slices, which can be coerced automatically into the
        // sentinel-terminated many pointer which is required by setenv.
        const setenv_res = setenv_fn_ptr(name, value, true);
        if (setenv_res == 0) {
            print.printDebug(
                "setting \"{s}\"=\"{s}\"",
                .{ name, value },
            );
        } else {
            print.printError(
                "failed to set \"{s}\"=\"{s}\", setenv returned: {d}",
                .{ name, value, setenv_res },
            );
        }
    }
}

fn getEnvValue(
    allocator: std.mem.Allocator,
    name: [:0]const u8,
    configuration: config.InjectorConfiguration,
) ?[:0]const u8 {
    const original_value = std.posix.getenv(name);
    if (std.mem.eql(u8, name, jvm.java_tool_options_env_var_name)) {
        return jvm.checkOTelJavaAgentJarAndGetModifiedJavaToolOptionsValue(
            allocator,
            original_value,
            configuration,
        );
    } else if (std.mem.eql(u8, name, node_js.node_options_env_var_name)) {
        return node_js.checkNodeJsAutoInstrumentationAgentAndGetModifiedNodeOptionsValue(
            allocator,
            original_value,
            configuration,
        );
    } else if (std.mem.eql(u8, name, dotnet.coreclr_enable_profiling_env_var_name)) {
        if (dotnet.getDotnetValues(allocator, configuration)) |v| {
            return v.coreclr_enable_profiling;
        }
    } else if (std.mem.eql(u8, name, dotnet.coreclr_profiler_env_var_name)) {
        if (dotnet.getDotnetValues(allocator, configuration)) |v| {
            return v.coreclr_profiler;
        }
    } else if (std.mem.eql(u8, name, dotnet.coreclr_profiler_path_env_var_name)) {
        if (dotnet.getDotnetValues(allocator, configuration)) |v| {
            return v.coreclr_profiler_path;
        }
    } else if (std.mem.eql(u8, name, dotnet.dotnet_additional_deps_env_var_name)) {
        if (dotnet.getDotnetValues(allocator, configuration)) |v| {
            return v.additional_deps;
        }
    } else if (std.mem.eql(u8, name, dotnet.dotnet_shared_store_env_var_name)) {
        if (dotnet.getDotnetValues(allocator, configuration)) |v| {
            return v.shared_store;
        }
    } else if (std.mem.eql(u8, name, dotnet.dotnet_startup_hooks_env_var_name)) {
        if (dotnet.getDotnetValues(allocator, configuration)) |v| {
            return v.startup_hooks;
        }
    } else if (std.mem.eql(u8, name, dotnet.otel_dotnet_auto_home_env_var_name)) {
        if (dotnet.getDotnetValues(allocator, configuration)) |v| {
            return v.otel_auto_home;
        }
    }

    return null;
}

fn setCustomEnvironmentVariables(
    allocator: std.mem.Allocator,
    setenv_fn_ptr: types.SetenvFnPtr,
    custom_env_vars: std.StringHashMap([]u8),
) void {
    if (custom_env_vars.count() == 0) {
        return;
    }
    var env_var_iterator = custom_env_vars.iterator();
    while (env_var_iterator.next()) |env_var| {
        const name = allocator.dupeZ(u8, env_var.key_ptr.*) catch |err| {
            print.printError(
                "error allocating memory for name when setting custom environment variable \"{}\"=\"{}\" (remaining custom environment variables will be skipped) : {}",
                .{
                    env_var.key_ptr,
                    env_var.value_ptr,
                    err,
                },
            );
            return;
        };
        const value = allocator.dupeZ(u8, env_var.value_ptr.*) catch |err| {
            print.printError(
                "error allocating memory for value when setting custom environment variable \"{}\"=\"{}\" (remaining custom environment variables will be skipped): {}",
                .{
                    env_var.key_ptr,
                    env_var.value_ptr,
                    err,
                },
            );
            return;
        };
        const setenv_res = setenv_fn_ptr(name, value, true);
        if (setenv_res == 0) {
            print.printDebug("setting \"{s}\"=\"{s}\"", .{ name, value });
        } else {
            print.printError(
                "failed to set \"{s}\"=\"{s}\", setenv returned: {d}",
                .{ name, value, setenv_res },
            );
        }
    }
}
