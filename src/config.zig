// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const build_options = @import("build_options");

const print = @import("print.zig");
const test_util = @import("test_util.zig");
const options = @import("config_generated.zig");
const proc_self_environ_parser = @import("proc_self_environ_parser.zig");

const testing = std.testing;

const max_line_length = 8192;
const empty_string = @constCast("");
const allowed_env_var_prefixes = build_options.allowed_env_var_prefixes;

pub const InjectorConfiguration = options.Configuration;
pub const default_jvm_auto_instrumentation_minimum_java_major_version = options.jvm_minimum_major_version.default_value;

const ConfigApplier = fn (gpa: std.mem.Allocator, key: []const u8, value: []u8, file_path: []const u8, configuration: *InjectorConfiguration) void;

var cached_configuration_optional: ?InjectorConfiguration = null;

/// Resolves defaults, the main file, alphabetical drop-ins, and environment overrides, then caches the result per process.
/// Missing or unreadable files and directories are skipped.
pub fn readConfiguration(io: std.Io, allocator: std.mem.Allocator, getenv_fn: proc_self_environ_parser.GetenvFn) InjectorConfiguration {
    if (cached_configuration_optional) |cached_configuration| {
        return cached_configuration;
    }

    const env_config_path = getenv_fn(io, allocator, options.config_file.env_name.?);
    defer if (env_config_path) |p| allocator.free(p);
    const config_file_path = if (env_config_path) |value| options.config_file.environmentString(value) else options.config_file.default_value;

    return readConfigurationFromPath(io, allocator, config_file_path, getenv_fn) catch |err| {
        print.printError("Cannot allocate memory while parsing configuration: {t}", .{err});
        return createEmptyConfiguration(allocator);
    };
}

fn createEmptyConfiguration(allocator: std.mem.Allocator) InjectorConfiguration {
    return InjectorConfiguration.initEmpty(allocator);
}

test "createEmptyConfiguration: safe to deinit without allocations" {
    var configuration = createEmptyConfiguration(testing.failing_allocator);
    defer configuration.deinit(testing.failing_allocator);

    try testing.expectEqualStrings("", configuration.all_auto_instrumentation_agents_env_path);
    try testing.expectEqual(@as(u32, 8), configuration.dotnet_auto_instrumentation_minimum_dotnet_major_version);
    try testing.expectEqual(@as(u32, 8), configuration.jvm_auto_instrumentation_minimum_java_major_version);
}

fn readConfigurationFromPath(io: std.Io, allocator: std.mem.Allocator, cfg_file_path: []const u8, getenv_fn: proc_self_environ_parser.GetenvFn) std.mem.Allocator.Error!InjectorConfiguration {
    // We create a good amount of intermediate values - keys, values, comma-separated parts of strings, default config
    // values that might or might not be later overwritten, etc. It would tricky and error-prone to release each of
    // them individually at exactly the right time. Instead, we use an arena for all allocations (including the actual
    // config values). Once we have compiled the final configuration values, we copy them over to memory allocated via
    // the allocator passed in via the allocator parameter, then we free all intermediate values in bulk by deinit-ing
    // the arena.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var preliminary_configuration = try createDefaultConfiguration(arena_allocator);
    readConfigurationFile(io, arena_allocator, cfg_file_path, &preliminary_configuration);
    readConfigurationDirectory(io, arena_allocator, &preliminary_configuration, getenv_fn);
    readConfigurationFromEnvironment(io, arena_allocator, &preliminary_configuration, getenv_fn);
    readAllAgentsEnvFile(
        io,
        arena_allocator,
        preliminary_configuration.all_auto_instrumentation_agents_env_path,
        &preliminary_configuration,
    );

    const final_configuration =
        try copyToPermanentlyAllocatedHeap(allocator, preliminary_configuration);
    cached_configuration_optional = final_configuration;
    return final_configuration;
}

test "readConfiguration: should cache configuration and return same instance on subsequent calls" {
    const allocator = testing.allocator;
    defer {
        if (cached_configuration_optional) |*config| {
            config.deinit(allocator);
        }
        cached_configuration_optional = null;
    }

    const original_environ = try test_util.clearStdCEnviron();
    defer test_util.resetStdCEnviron(original_environ);

    const config1 = readConfiguration(testing.io, allocator, test_util.posixGetenv);
    const config2 = readConfiguration(testing.io, allocator, test_util.posixGetenv);

    // Compare the pointer values directly to ensure the caching worked
    try testing.expectEqual(@intFromPtr(config1.dotnet_auto_instrumentation_agent_path_prefix.ptr), @intFromPtr(config2.dotnet_auto_instrumentation_agent_path_prefix.ptr));
    try testing.expectEqual(@intFromPtr(config1.jvm_auto_instrumentation_agent_path.ptr), @intFromPtr(config2.jvm_auto_instrumentation_agent_path.ptr));
}

test "readConfiguration: respects OTEL_INJECTOR_CONFIG_FILE environment variable" {
    const allocator = testing.allocator;
    defer {
        if (cached_configuration_optional) |*config| {
            config.deinit(allocator);
        }
        cached_configuration_optional = null;
    }

    const cwd_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cwd_path);
    const absolute_path_to_config_file =
        try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/config/all_values.conf" });
    defer allocator.free(absolute_path_to_config_file);

    const env_string = try std.fmt.allocPrint(allocator, "{s}={s}", .{ options.config_file.env_name.?, absolute_path_to_config_file });
    defer allocator.free(env_string);

    const original_environ = try test_util.setStdCEnviron(&[1][]const u8{env_string});
    defer test_util.resetStdCEnviron(original_environ);

    const configuration = readConfiguration(testing.io, allocator, test_util.posixGetenv);
    // No separate deinit — cleanup is handled by the defer block above via cached_configuration_optional

    try testing.expectEqualStrings(
        "/custom/path/to/dotnet/instrumentation",
        configuration.dotnet_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        "/custom/path/to/jvm/javaagent.jar",
        configuration.jvm_auto_instrumentation_agent_path,
    );
}

test "readConfigurationFromPath: loads from the specified path" {
    const allocator = testing.allocator;

    const cwd_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cwd_path);
    const absolute_path_to_config_file =
        try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/config/all_values.conf" });
    defer allocator.free(absolute_path_to_config_file);

    const original_environ = try test_util.clearStdCEnviron();
    defer test_util.resetStdCEnviron(original_environ);

    var configuration = try readConfigurationFromPath(testing.io, allocator, absolute_path_to_config_file, test_util.posixGetenv);
    defer configuration.deinit(allocator);

    try testing.expectEqualStrings(
        "/custom/path/to/dotnet/instrumentation",
        configuration.dotnet_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqual(@as(u32, 6), configuration.dotnet_auto_instrumentation_minimum_dotnet_major_version);
    try testing.expectEqualStrings(
        "/custom/path/to/jvm/javaagent.jar",
        configuration.jvm_auto_instrumentation_agent_path,
    );
}

test "readConfigurationFromPath: file does not exist, no environment variables" {
    const allocator = testing.allocator;

    const original_environ = try test_util.clearStdCEnviron();
    defer test_util.resetStdCEnviron(original_environ);

    var configuration = try readConfigurationFromPath(testing.io, allocator, @constCast("/does/not/exist"), test_util.posixGetenv);
    defer configuration.deinit(allocator);

    try testing.expectEqualStrings(
        "",
        configuration.dotnet_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        "",
        configuration.jvm_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        "",
        configuration.nodejs_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        "",
        configuration.python_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        "/etc/opentelemetry/injector/default_env.conf",
        configuration.all_auto_instrumentation_agents_env_path,
    );
    try testing.expectEqual(0, configuration.all_auto_instrumentation_agents_env_vars.count());
    try testing.expectEqual(0, configuration.include_paths.len);
    try testing.expectEqual(0, configuration.exclude_paths.len);
    try testing.expectEqual(0, configuration.include_with_arguments.len);
    try testing.expectEqual(0, configuration.exclude_with_arguments.len);
    try testing.expectEqual(
        @as(u32, 8),
        configuration.dotnet_auto_instrumentation_minimum_dotnet_major_version,
    );
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.dotnet, "!configuration.auto_instrumentation_disabled.dotnet");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.jvm, "!configuration.auto_instrumentation_disabled.jvm");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.nodejs, "!configuration.auto_instrumentation_disabled.nodejs");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.python, "!configuration.auto_instrumentation_disabled.python");
}

test "readConfigurationFromPath: file does not exist, environment variables are set" {
    const allocator = testing.allocator;

    const original_environ = try test_util.setStdCEnviron(&[9][]const u8{
        "DOTNET_AUTO_INSTRUMENTATION_AGENT_PATH_PREFIX=/path/from/env/var/dotnet",
        "DOTNET_AUTO_INSTRUMENTATION_MINIMUM_DOTNET_MAJOR_VERSION=6",
        "JVM_AUTO_INSTRUMENTATION_AGENT_PATH=/path/from/env/var/jvm",
        "NODEJS_AUTO_INSTRUMENTATION_AGENT_PATH=/path/from/env/var/nodejs",
        "PYTHON_AUTO_INSTRUMENTATION_AGENT_PATH_PREFIX=/path/from/env/var/python",
        "OTEL_INJECTOR_INCLUDE_PATHS=/path/from/env/var/include1,/path/from/env/var/include2",
        "OTEL_INJECTOR_EXCLUDE_PATHS=/path/from/env/var/exclude1,/path/from/env/var/exclude2",
        "OTEL_INJECTOR_INCLUDE_WITH_ARGUMENTS=--from-env-var-include1,--from-env-var-include2",
        "OTEL_INJECTOR_EXCLUDE_WITH_ARGUMENTS=--from-env-var-exclude1,--from-env-var-exclude2",
    });
    defer test_util.resetStdCEnviron(original_environ);

    var configuration = try readConfigurationFromPath(testing.io, allocator, @constCast("/does/not/exist"), test_util.posixGetenv);
    defer configuration.deinit(allocator);

    try testing.expectEqualStrings(
        "/path/from/env/var/dotnet",
        configuration.dotnet_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqual(@as(u32, 6), configuration.dotnet_auto_instrumentation_minimum_dotnet_major_version);
    try testing.expectEqualStrings(
        "/path/from/env/var/jvm",
        configuration.jvm_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        "/path/from/env/var/nodejs",
        configuration.nodejs_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        "/path/from/env/var/python",
        configuration.python_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        "/etc/opentelemetry/injector/default_env.conf",
        configuration.all_auto_instrumentation_agents_env_path,
    );
    try testing.expectEqual(0, configuration.all_auto_instrumentation_agents_env_vars.count());
    try testing.expectEqual(2, configuration.include_paths.len);
    try testing.expectEqualStrings("/path/from/env/var/include1", configuration.include_paths[0]);
    try testing.expectEqualStrings("/path/from/env/var/include2", configuration.include_paths[1]);
    try testing.expectEqual(2, configuration.exclude_paths.len);
    try testing.expectEqualStrings("/path/from/env/var/exclude1", configuration.exclude_paths[0]);
    try testing.expectEqualStrings("/path/from/env/var/exclude2", configuration.exclude_paths[1]);
    try testing.expectEqual(2, configuration.include_with_arguments.len);
    try testing.expectEqualStrings("--from-env-var-include1", configuration.include_with_arguments[0]);
    try testing.expectEqualStrings("--from-env-var-include2", configuration.include_with_arguments[1]);
    try testing.expectEqual(2, configuration.exclude_with_arguments.len);
    try testing.expectEqualStrings("--from-env-var-exclude1", configuration.exclude_with_arguments[0]);
    try testing.expectEqualStrings("--from-env-var-exclude2", configuration.exclude_with_arguments[1]);
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.dotnet, "!configuration.auto_instrumentation_disabled.dotnet");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.jvm, "!configuration.auto_instrumentation_disabled.jvm");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.nodejs, "!configuration.auto_instrumentation_disabled.nodejs");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.python, "!configuration.auto_instrumentation_disabled.python");
}

test "readConfigurationFromPath: all configuration values from file, no environment variables" {
    const allocator = testing.allocator;
    const cwd_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cwd_path);
    const absolute_path_to_config_file =
        try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/config/all_values.conf" });
    defer allocator.free(absolute_path_to_config_file);

    const original_environ = try test_util.clearStdCEnviron();
    defer test_util.resetStdCEnviron(original_environ);

    var configuration = try readConfigurationFromPath(testing.io, allocator, absolute_path_to_config_file, test_util.posixGetenv);
    defer configuration.deinit(allocator);

    try testing.expectEqualStrings(
        "/custom/path/to/dotnet/instrumentation",
        configuration.dotnet_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqual(@as(u32, 6), configuration.dotnet_auto_instrumentation_minimum_dotnet_major_version);
    try testing.expectEqualStrings(
        "/custom/path/to/jvm/javaagent.jar",
        configuration.jvm_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        "/custom/path/to/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/build/src/register.js",
        configuration.nodejs_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        "/custom/path/to/python",
        configuration.python_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        "/custom/path/to/auto_instrumentation_env.conf",
        configuration.all_auto_instrumentation_agents_env_path,
    );
    try testing.expectEqual(0, configuration.all_auto_instrumentation_agents_env_vars.count());
    try testing.expectEqual(3, configuration.include_paths.len);
    try testing.expectEqualStrings("/app/*", configuration.include_paths[0]);
    try testing.expectEqualStrings("/home/user/test/*", configuration.include_paths[1]);
    try testing.expectEqualStrings("/another_dir/*", configuration.include_paths[2]);
    try testing.expectEqual(3, configuration.exclude_paths.len);
    try testing.expectEqualStrings("/usr/*", configuration.exclude_paths[0]);
    try testing.expectEqualStrings("/opt/*", configuration.exclude_paths[1]);
    try testing.expectEqualStrings("/another_excluded_dir/*", configuration.exclude_paths[2]);
    try testing.expectEqual(4, configuration.include_with_arguments.len);
    try testing.expectEqualStrings("-jar", configuration.include_with_arguments[0]);
    try testing.expectEqualStrings("*my-app*", configuration.include_with_arguments[1]);
    try testing.expectEqualStrings("*.js", configuration.include_with_arguments[2]);
    try testing.expectEqualStrings("*.dll", configuration.include_with_arguments[3]);
    try testing.expectEqual(3, configuration.exclude_with_arguments.len);
    try testing.expectEqualStrings("-javaagent*", configuration.exclude_with_arguments[0]);
    try testing.expectEqualStrings("*@opentelemetry-js*", configuration.exclude_with_arguments[1]);
    try testing.expectEqualStrings("-debug", configuration.exclude_with_arguments[2]);
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.dotnet, "!configuration.auto_instrumentation_disabled.dotnet");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.jvm, "!configuration.auto_instrumentation_disabled.jvm");
    try test_util.expectWithMessage(configuration.auto_instrumentation_disabled.nodejs, "configuration.auto_instrumentation_disabled.nodejs");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.python, "!configuration.auto_instrumentation_disabled.python");
}

test "readConfigurationFromPath: override some configuration values from file with environment variables" {
    const allocator = testing.allocator;
    const cwd_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cwd_path);
    const absolute_path_to_config_file =
        try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/config/all_values.conf" });
    defer allocator.free(absolute_path_to_config_file);

    const original_environ = try test_util.setStdCEnviron(&[6][]const u8{
        "DOTNET_AUTO_INSTRUMENTATION_AGENT_PATH_PREFIX=/path/from/env/var/dotnet",
        "DOTNET_AUTO_INSTRUMENTATION_MINIMUM_DOTNET_MAJOR_VERSION=9",
        "NODEJS_AUTO_INSTRUMENTATION_AGENT_PATH=/path/from/env/var/nodejs",
        "OTEL_INJECTOR_AUTO_INSTRUMENTATION_DISABLED=python",
        "OTEL_INJECTOR_INCLUDE_PATHS=/path/from/env/var/include1,/path/from/env/var/include2",
        "OTEL_INJECTOR_EXCLUDE_WITH_ARGUMENTS=--from-env-var-exclude1,--from-env-var-exclude2",
    });
    defer test_util.resetStdCEnviron(original_environ);

    var configuration = try readConfigurationFromPath(testing.io, allocator, absolute_path_to_config_file, test_util.posixGetenv);
    defer configuration.deinit(allocator);

    try testing.expectEqualStrings(
        "/path/from/env/var/dotnet",
        configuration.dotnet_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqual(@as(u32, 9), configuration.dotnet_auto_instrumentation_minimum_dotnet_major_version);
    try testing.expectEqualStrings(
        "/custom/path/to/jvm/javaagent.jar",
        configuration.jvm_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        "/path/from/env/var/nodejs",
        configuration.nodejs_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        "/custom/path/to/python",
        configuration.python_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        "/custom/path/to/auto_instrumentation_env.conf",
        configuration.all_auto_instrumentation_agents_env_path,
    );
    try testing.expectEqual(0, configuration.all_auto_instrumentation_agents_env_vars.count());
    try testing.expectEqual(2, configuration.include_paths.len);
    try testing.expectEqualStrings("/path/from/env/var/include1", configuration.include_paths[0]);
    try testing.expectEqualStrings("/path/from/env/var/include2", configuration.include_paths[1]);
    try testing.expectEqual(3, configuration.exclude_paths.len);
    try testing.expectEqualStrings("/usr/*", configuration.exclude_paths[0]);
    try testing.expectEqualStrings("/opt/*", configuration.exclude_paths[1]);
    try testing.expectEqualStrings("/another_excluded_dir/*", configuration.exclude_paths[2]);
    try testing.expectEqual(4, configuration.include_with_arguments.len);
    try testing.expectEqualStrings("-jar", configuration.include_with_arguments[0]);
    try testing.expectEqualStrings("*my-app*", configuration.include_with_arguments[1]);
    try testing.expectEqualStrings("*.js", configuration.include_with_arguments[2]);
    try testing.expectEqualStrings("*.dll", configuration.include_with_arguments[3]);
    try testing.expectEqual(2, configuration.exclude_with_arguments.len);
    try testing.expectEqualStrings("--from-env-var-exclude1", configuration.exclude_with_arguments[0]);
    try testing.expectEqualStrings("--from-env-var-exclude2", configuration.exclude_with_arguments[1]);
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.dotnet, "!configuration.auto_instrumentation_disabled.dotnet");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.jvm, "!configuration.auto_instrumentation_disabled.jvm");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.nodejs, "!configuration.auto_instrumentation_disabled.nodejs");
    try test_util.expectWithMessage(configuration.auto_instrumentation_disabled.python, "configuration.auto_instrumentation_disabled.python");
}

fn createDefaultConfiguration(arena_allocator: std.mem.Allocator) std.mem.Allocator.Error!InjectorConfiguration {
    var configuration = createEmptyConfiguration(arena_allocator);
    inline for (options.file_options) |option| {
        @field(configuration, option.file_key.?) = try option.copy(arena_allocator, option.initialValue());
    }
    return configuration;
}

test "applyKeyValueToGeneralOptions: parses runtime minimum versions and retains previous values for invalid input" {
    const Case = struct { value: []const u8, expected: u32 };
    inline for (.{ options.dotnet_minimum_major_version, options.jvm_minimum_major_version }) |option| {
        for ([_]Case{
            .{ .value = "0", .expected = 0 },
            .{ .value = "1", .expected = 1 },
            .{ .value = "6", .expected = 6 },
            .{ .value = " 21\t", .expected = 21 },
            .{ .value = "0\n", .expected = 0 },
            .{ .value = "21\r\n", .expected = 21 },
            .{ .value = "4294967295", .expected = std.math.maxInt(u32) },
            .{ .value = "", .expected = 8 },
            .{ .value = "true", .expected = 8 },
            .{ .value = "-1", .expected = 8 },
            .{ .value = "1.6", .expected = 8 },
            .{ .value = "4294967296", .expected = 8 },
        }) |case| {
            var configuration = createEmptyConfiguration(testing.allocator);
            defer configuration.deinit(testing.allocator);

            applyKeyValueToGeneralOptions(testing.allocator, option.file_key.?, @constCast(case.value), "test", &configuration);

            try testing.expectEqual(case.expected, @field(configuration, option.file_key.?));
        }
    }
}

test "JVM minimum Java major version: reads config files and applies environment overrides" {
    const allocator = testing.allocator;
    defer cached_configuration_optional = null;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "injector.conf",
        .data = "jvm_auto_instrumentation_minimum_java_major_version = 6\n",
    });

    const path = try tmp.dir.realPathFileAlloc(testing.io, "injector.conf", allocator);
    defer allocator.free(path);

    const directory = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(directory);

    const config_dir_env = try std.fmt.allocPrint(allocator, "OTEL_INJECTOR_CONFIG_DIR={s}/no-conf-dir", .{directory});
    defer allocator.free(config_dir_env);

    const Case = struct { value: ?[]const u8, expected: u32 };
    for ([_]Case{
        .{ .value = null, .expected = 6 },
        .{ .value = "0", .expected = 0 },
        .{ .value = " 9\t", .expected = 9 },
        .{ .value = "0\n", .expected = 0 },
        .{ .value = "invalid", .expected = 6 },
        .{ .value = "-1", .expected = 6 },
        .{ .value = "4294967296", .expected = 6 },
    }) |case| {
        var env_vars: [2][]const u8 = .{ config_dir_env, "" };

        if (case.value) |value| {
            env_vars[1] = try std.fmt.allocPrint(allocator, "{s}={s}", .{ options.jvm_minimum_major_version.env_name.?, value });
        }
        defer if (case.value != null) allocator.free(env_vars[1]);

        const original = try test_util.setStdCEnviron(&env_vars);
        defer test_util.resetStdCEnviron(original);

        var configuration = try readConfigurationFromPath(testing.io, allocator, path, test_util.posixGetenv);
        defer configuration.deinit(allocator);

        try testing.expectEqual(case.expected, configuration.jvm_auto_instrumentation_minimum_java_major_version);
    }
}

fn applyKeyValueToGeneralOptions(arena_allocator: std.mem.Allocator, key: []const u8, value: []u8, cfg_file_path: []const u8, configuration: *InjectorConfiguration) void {
    inline for (options.file_options) |option| {
        if (std.mem.eql(u8, key, option.file_key.?)) {
            const parsed = option.parseFile(arena_allocator, value, cfg_file_path) catch |err| {
                if (err == error.InvalidValue) {
                    option.warnInvalidValue(value, cfg_file_path);
                } else {
                    print.printError("error parsing {s} value from configuration file {s}: {}", .{ key, cfg_file_path, err });
                }
                return;
            };
            const setting = &@field(configuration, option.file_key.?);
            if (comptime option.repeated == .append) {
                setting.* = std.mem.concat(arena_allocator, []const u8, &.{ setting.*, parsed }) catch |err| {
                    print.printError("error concatenating {s} from configuration file {s}: {}", .{ key, cfg_file_path, err });
                    return;
                };
            } else {
                setting.* = parsed;
            }
            return;
        }
    }
    print.printError("ignoring unknown configuration key in {s}: {s}={s}", .{ cfg_file_path, key, value });
}

fn readConfigurationFile(io: std.Io, arena_allocator: std.mem.Allocator, cfg_file_path: []const u8, configuration: *InjectorConfiguration) void {
    print.printDebug("reading configuration file from {s}.", .{cfg_file_path});
    const config_file = std.Io.Dir.cwd().openFile(io, cfg_file_path, .{}) catch |err| {
        print.printDebug(
            "The configuration file {s} does not exist or cannot be opened. Configuration will use default values and environment variables only. Error: {t}",
            .{ cfg_file_path, err },
        );
        return;
    };
    defer config_file.close(io);

    parseConfiguration(
        io,
        arena_allocator,
        configuration,
        config_file,
        cfg_file_path,
        applyKeyValueToGeneralOptions,
    );
    print.printDebug("successfully read configuration file from {s}.", .{cfg_file_path});
}

/// Reads configuration drop-in files from the conf.d directory. Each installed language package
/// (e.g., opentelemetry-java-autoinstrumentation) places its configuration in this directory.
/// Files are read in alphabetical order; later files can override earlier ones.
fn readConfigurationDirectory(io: std.Io, arena_allocator: std.mem.Allocator, configuration: *InjectorConfiguration, getenv_fn: proc_self_environ_parser.GetenvFn) void {
    const env_config_dir = getenv_fn(io, arena_allocator, options.config_dir.env_name.?);
    const config_dir_path = if (env_config_dir) |value| options.config_dir.environmentString(value) else options.config_dir.default_value;

    print.printDebug("reading configuration drop-in files from {s}.", .{config_dir_path});

    var dir = std.Io.Dir.cwd().openDir(io, config_dir_path, .{ .iterate = true }) catch |err| {
        print.printDebug(
            "The configuration directory {s} does not exist or cannot be opened. Error: {t}",
            .{ config_dir_path, err },
        );
        return;
    };
    defer dir.close(io);

    // Collect and sort file names to ensure deterministic ordering
    var file_names: std.ArrayList([]const u8) = std.ArrayList([]const u8).initCapacity(arena_allocator, 16) catch {
        print.printDebug("Failed to allocate memory for conf.d file list", .{});
        return;
    };
    var dir_iter = dir.iterate();
    while (dir_iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".conf")) continue;
        const name_copy = std.fmt.allocPrint(arena_allocator, "{s}", .{entry.name}) catch continue;
        file_names.append(arena_allocator, name_copy) catch continue;
    }

    // Sort alphabetically
    std.mem.sort([]const u8, file_names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    // Read each file
    for (file_names.items) |file_name| {
        const full_path = std.fmt.allocPrint(arena_allocator, "{s}/{s}", .{ config_dir_path, file_name }) catch continue;
        print.printDebug("reading configuration drop-in file: {s}", .{full_path});
        readConfigurationFile(io, arena_allocator, full_path, configuration);
    }
}

fn applyKeyValueToAllAgentsEnv(_: std.mem.Allocator, key: []const u8, value: []u8, _file_path: []const u8, _configuration: *InjectorConfiguration) void {
    if (!isAllowedEnvVarKey(key)) {
        print.printWarn(
            "environment variable {s} does not match any allowed prefix from this build ({s}). ignoring.",
            .{ key, allowed_env_var_prefixes },
        );
        return;
    }
    _configuration.all_auto_instrumentation_agents_env_vars.put(key, value) catch |e| {
        print.printError("error storing environment variable {s} from file {s}: {}", .{ key, _file_path, e });
    };
}

fn isAllowedEnvVarKey(key: []const u8) bool {
    return hasAllowedPrefix(key, allowed_env_var_prefixes);
}

fn hasAllowedPrefix(key: []const u8, prefixes_csv: []const u8) bool {
    var prefixes = std.mem.splitScalar(u8, prefixes_csv, ',');
    while (prefixes.next()) |raw_prefix| {
        const prefix = std.mem.trim(u8, raw_prefix, " \t\r\n");
        if (prefix.len == 0) {
            continue;
        }
        if (std.mem.startsWith(u8, key, prefix)) {
            return true;
        }
    }
    return false;
}

fn readAllAgentsEnvFile(io: std.Io, arena_allocator: std.mem.Allocator, env_file_path: []const u8, configuration: *InjectorConfiguration) void {
    if (env_file_path.len == 0) {
        return;
    }

    const env_file = std.Io.Dir.cwd().openFile(io, env_file_path, .{}) catch |err| {
        print.printDebug("The configuration file {s} does not exist or cannot be opened. Error: {}", .{ env_file_path, err });
        return;
    };
    defer env_file.close(io);

    parseConfiguration(
        io,
        arena_allocator,
        configuration,
        env_file,
        env_file_path,
        applyKeyValueToAllAgentsEnv,
    );
}

fn parseConfiguration(
    io: std.Io,
    arena_allocator: std.mem.Allocator,
    configuration: *InjectorConfiguration,
    config_file: std.Io.File,
    cfg_file_path: []const u8,
    comptime applyKeyValueToConfig: ConfigApplier,
) void {
    var buf: [max_line_length]u8 = undefined;
    var reader = config_file.reader(io, &buf);
    while (takeSentinelOrDiscardOverlyLongLine(&reader, cfg_file_path)) |line| {
        if (parseLine(arena_allocator, line, cfg_file_path)) |kv| {
            applyKeyValueToConfig(arena_allocator, kv.key, kv.value, cfg_file_path, configuration);
        }
    } else |err| switch (err) {
        error.ReadFailed => {
            print.printError("Failed to read configuration file {s}", .{cfg_file_path});
            return;
        },
        // if the file does not end with a newline, we still need to parse the last line
        error.EndOfStream => {
            var buffer: [max_line_length]u8 = undefined;
            const chars = reader.interface.readSliceShort(&buffer) catch 0;
            if (parseLine(arena_allocator, buffer[0..chars], cfg_file_path)) |kv| {
                applyKeyValueToConfig(arena_allocator, kv.key, kv.value, cfg_file_path, configuration);
            }
        },
    }
}

fn copyToPermanentlyAllocatedHeap(
    allocator: std.mem.Allocator,
    preliminary_configuration: InjectorConfiguration,
) std.mem.Allocator.Error!InjectorConfiguration {
    var configuration = createEmptyConfiguration(allocator);
    errdefer configuration.deinit(allocator);
    inline for (options.file_options) |option| {
        @field(configuration, option.file_key.?) = try option.copy(allocator, @field(preliminary_configuration, option.file_key.?));
    }
    configuration.all_auto_instrumentation_agents_env_vars = try copyMap(allocator, preliminary_configuration.all_auto_instrumentation_agents_env_vars);
    return configuration;
}

test "copyToPermanentlyAllocatedHeap: frees partial copies on allocation failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var preliminary_configuration = try createDefaultConfiguration(allocator);
    preliminary_configuration.dotnet_auto_instrumentation_agent_path_prefix = try allocator.dupe(u8, "/opt/agent");
    preliminary_configuration.include_paths = try options.include_paths.parse(allocator, "/app/*,/utilities/*", "test");
    preliminary_configuration.exclude_paths = try options.exclude_paths.parse(allocator, "/app/excluded/*", "test");
    inline for (.{ "OTEL_SERVICE_NAME", "OTEL_SERVICE_NAMESPACE" }) |key| {
        try preliminary_configuration.all_auto_instrumentation_agents_env_vars.put(try allocator.dupe(u8, key), try allocator.dupe(u8, "value"));
    }

    const Test = struct {
        fn run(copy_allocator: std.mem.Allocator, source: InjectorConfiguration) !void {
            var copied = try copyToPermanentlyAllocatedHeap(copy_allocator, source);
            defer copied.deinit(copy_allocator);
            inline for (options.file_options) |option| {
                try testing.expectEqualDeep(@field(source, option.file_key.?), @field(copied, option.file_key.?));
            }
            try testing.expectEqual(source.all_auto_instrumentation_agents_env_vars.count(), copied.all_auto_instrumentation_agents_env_vars.count());
            var it = source.all_auto_instrumentation_agents_env_vars.iterator();
            while (it.next()) |entry| {
                try testing.expectEqualStrings(entry.value_ptr.*, copied.all_auto_instrumentation_agents_env_vars.get(entry.key_ptr.*) orelse "");
            }
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Test.run, .{preliminary_configuration});
}

fn takeSentinelOrDiscardOverlyLongLine(reader: *std.Io.File.Reader, cfg_file_path: []const u8) ![]u8 {
    if (reader.interface.takeSentinel('\n')) |slice| {
        return slice;
    } else |err| switch (err) {
        error.StreamTooLong => {
            print.printError(
                "A line in configuration file {s} exceeds the maximum allowed length of {d} characters and will be ignored.",
                .{ cfg_file_path, max_line_length },
            );
            // Ignore lines that are too long for the buffer; advance the the read positon to the next delimiter to
            // avoid stream corruption.
            _ = try reader.interface.discardDelimiterInclusive('\n');
            return empty_string;
        },
        else => |leftover_err| return leftover_err,
    }
}

test "readConfigurationFile: file does not exist" {
    const allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var configuration = try createDefaultConfiguration(arena_allocator);
    readConfigurationFile(testing.io, arena_allocator, "/does/not/exist", &configuration);

    try testing.expectEqualStrings(
        "",
        configuration.dotnet_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        "",
        configuration.jvm_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        "",
        configuration.nodejs_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        "",
        configuration.python_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        "/etc/opentelemetry/injector/default_env.conf",
        configuration.all_auto_instrumentation_agents_env_path,
    );
    try testing.expectEqual(0, configuration.all_auto_instrumentation_agents_env_vars.count());
    try testing.expectEqual(0, configuration.include_paths.len);
    try testing.expectEqual(0, configuration.exclude_paths.len);
    try testing.expectEqual(0, configuration.include_with_arguments.len);
    try testing.expectEqual(0, configuration.exclude_with_arguments.len);
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.dotnet, "!configuration.auto_instrumentation_disabled.dotnet");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.jvm, "!configuration.auto_instrumentation_disabled.jvm");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.nodejs, "!configuration.auto_instrumentation_disabled.nodejs");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.python, "!configuration.auto_instrumentation_disabled.python");
}

test "readConfigurationFile: empty file" {
    const allocator = testing.allocator;
    const cwd_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cwd_path);
    const absolute_path_to_config_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/config/empty.conf" });
    defer allocator.free(absolute_path_to_config_file);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var configuration = try createDefaultConfiguration(arena_allocator);
    readConfigurationFile(testing.io, arena_allocator, absolute_path_to_config_file, &configuration);

    try testing.expectEqualStrings(
        "",
        configuration.dotnet_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        "",
        configuration.jvm_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        "",
        configuration.nodejs_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        "",
        configuration.python_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        "/etc/opentelemetry/injector/default_env.conf",
        configuration.all_auto_instrumentation_agents_env_path,
    );
    try testing.expectEqual(0, configuration.all_auto_instrumentation_agents_env_vars.count());
    try testing.expectEqual(0, configuration.include_paths.len);
    try testing.expectEqual(0, configuration.exclude_paths.len);
    try testing.expectEqual(0, configuration.include_with_arguments.len);
    try testing.expectEqual(0, configuration.exclude_with_arguments.len);
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.dotnet, "!configuration.auto_instrumentation_disabled.dotnet");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.jvm, "!configuration.auto_instrumentation_disabled.jvm");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.nodejs, "!configuration.auto_instrumentation_disabled.nodejs");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.python, "!configuration.auto_instrumentation_disabled.python");
}

test "readConfigurationFile: all configuration values" {
    const allocator = testing.allocator;
    const cwd_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cwd_path);
    const absolute_path_to_config_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/config/all_values.conf" });
    defer allocator.free(absolute_path_to_config_file);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var configuration = try createDefaultConfiguration(arena_allocator);
    readConfigurationFile(testing.io, arena_allocator, absolute_path_to_config_file, &configuration);

    try testing.expectEqualStrings(
        "/custom/path/to/dotnet/instrumentation",
        configuration.dotnet_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        "/custom/path/to/jvm/javaagent.jar",
        configuration.jvm_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        "/custom/path/to/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/build/src/register.js",
        configuration.nodejs_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        "/custom/path/to/python",
        configuration.python_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        "/custom/path/to/ruby",
        configuration.ruby_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        "/custom/path/to/auto_instrumentation_env.conf",
        configuration.all_auto_instrumentation_agents_env_path,
    );
    try testing.expectEqual(0, configuration.all_auto_instrumentation_agents_env_vars.count());
    try testing.expectEqual(3, configuration.include_paths.len);
    try testing.expectEqualStrings("/app/*", configuration.include_paths[0]);
    try testing.expectEqualStrings("/home/user/test/*", configuration.include_paths[1]);
    try testing.expectEqualStrings("/another_dir/*", configuration.include_paths[2]);
    try testing.expectEqual(3, configuration.exclude_paths.len);
    try testing.expectEqualStrings("/usr/*", configuration.exclude_paths[0]);
    try testing.expectEqualStrings("/opt/*", configuration.exclude_paths[1]);
    try testing.expectEqualStrings("/another_excluded_dir/*", configuration.exclude_paths[2]);
    try testing.expectEqual(4, configuration.include_with_arguments.len);
    try testing.expectEqualStrings("-jar", configuration.include_with_arguments[0]);
    try testing.expectEqualStrings("*my-app*", configuration.include_with_arguments[1]);
    try testing.expectEqualStrings("*.js", configuration.include_with_arguments[2]);
    try testing.expectEqualStrings("*.dll", configuration.include_with_arguments[3]);
    try testing.expectEqual(3, configuration.exclude_with_arguments.len);
    try testing.expectEqualStrings("-javaagent*", configuration.exclude_with_arguments[0]);
    try testing.expectEqualStrings("*@opentelemetry-js*", configuration.exclude_with_arguments[1]);
    try testing.expectEqualStrings("-debug", configuration.exclude_with_arguments[2]);
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.dotnet, "!configuration.auto_instrumentation_disabled.dotnet");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.jvm, "!configuration.auto_instrumentation_disabled.jvm");
    try test_util.expectWithMessage(configuration.auto_instrumentation_disabled.nodejs, "configuration.auto_instrumentation_disabled.nodejs");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.python, "!configuration.auto_instrumentation_disabled.python");
}

test "readConfigurationFile: all configuration values plus whitespace and comments" {
    const allocator = testing.allocator;
    const cwd_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cwd_path);
    const absolute_path_to_config_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/config/with_comments_and_whitespace.conf" });
    defer allocator.free(absolute_path_to_config_file);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var configuration = try createDefaultConfiguration(arena_allocator);
    readConfigurationFile(testing.io, arena_allocator, absolute_path_to_config_file, &configuration);

    try testing.expectEqualStrings(
        "/custom/path/to/dotnet/instrumentation",
        configuration.dotnet_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        "/custom/path/to/jvm/javaagent.jar",
        configuration.jvm_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        "/custom/path/to/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/build/src/register.js",
        configuration.nodejs_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        "",
        configuration.python_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        "/custom/path/to/auto_instrumentation_env.conf",
        configuration.all_auto_instrumentation_agents_env_path,
    );
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.dotnet, "!configuration.auto_instrumentation_disabled.dotnet");
    try test_util.expectWithMessage(configuration.auto_instrumentation_disabled.jvm, "configuration.auto_instrumentation_disabled.jvm");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.nodejs, "!configuration.auto_instrumentation_disabled.nodejs");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.python, "!configuration.auto_instrumentation_disabled.python");
}

test "readConfigurationFile: does not parse overly long lines" {
    const allocator = testing.allocator;
    const cwd_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cwd_path);
    const absolute_path_to_config_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/config/very_long_lines.conf" });
    defer allocator.free(absolute_path_to_config_file);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var configuration = try createDefaultConfiguration(arena_allocator);
    readConfigurationFile(testing.io, arena_allocator, absolute_path_to_config_file, &configuration);

    try testing.expectEqualStrings(
        "",
        configuration.dotnet_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        "/this/line/should/be/parsed",
        configuration.jvm_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        "",
        configuration.nodejs_auto_instrumentation_agent_path,
    );
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.dotnet, "!configuration.auto_instrumentation_disabled.dotnet");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.jvm, "!configuration.auto_instrumentation_disabled.jvm");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.nodejs, "!configuration.auto_instrumentation_disabled.nodejs");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.python, "!configuration.auto_instrumentation_disabled.python");
}

test "readConfigurationFile: auto_instrumentation_disabled=* disables all runtimes" {
    const allocator = testing.allocator;
    const cwd_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cwd_path);
    const absolute_path_to_config_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/config/auto_instrumentation_disabled_star.conf" });
    defer allocator.free(absolute_path_to_config_file);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var configuration = try createDefaultConfiguration(arena_allocator);
    readConfigurationFile(testing.io, arena_allocator, absolute_path_to_config_file, &configuration);

    try test_util.expectWithMessage(configuration.auto_instrumentation_disabled.dotnet, "configuration.auto_instrumentation_disabled.dotnet");
    try test_util.expectWithMessage(configuration.auto_instrumentation_disabled.jvm, "configuration.auto_instrumentation_disabled.jvm");
    try test_util.expectWithMessage(configuration.auto_instrumentation_disabled.nodejs, "configuration.auto_instrumentation_disabled.nodejs");
    try test_util.expectWithMessage(configuration.auto_instrumentation_disabled.python, "configuration.auto_instrumentation_disabled.python");
}

test "readConfigurationFile: auto_instrumentation_disabled with comma-separated list" {
    const allocator = testing.allocator;
    const cwd_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cwd_path);
    const absolute_path_to_config_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/config/auto_instrumentation_disabled_list.conf" });
    defer allocator.free(absolute_path_to_config_file);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var configuration = try createDefaultConfiguration(arena_allocator);
    readConfigurationFile(testing.io, arena_allocator, absolute_path_to_config_file, &configuration);

    try test_util.expectWithMessage(configuration.auto_instrumentation_disabled.dotnet, "configuration.auto_instrumentation_disabled.dotnet");
    try test_util.expectWithMessage(configuration.auto_instrumentation_disabled.jvm, "configuration.auto_instrumentation_disabled.jvm");
    try test_util.expectWithMessage(configuration.auto_instrumentation_disabled.nodejs, "configuration.auto_instrumentation_disabled.nodejs");
    try test_util.expectWithMessage(configuration.auto_instrumentation_disabled.python, "configuration.auto_instrumentation_disabled.python");
}

test "readConfigurationFile: multiple auto_instrumentation_disabled line: last one wins" {
    const allocator = testing.allocator;
    const cwd_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cwd_path);
    const absolute_path_to_config_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/config/auto_instrumentation_disabled_multiple_times.conf" });
    defer allocator.free(absolute_path_to_config_file);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var configuration = try createDefaultConfiguration(arena_allocator);
    readConfigurationFile(testing.io, arena_allocator, absolute_path_to_config_file, &configuration);

    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.dotnet, "!configuration.auto_instrumentation_disabled.dotnet");
    try test_util.expectWithMessage(configuration.auto_instrumentation_disabled.jvm, "configuration.auto_instrumentation_disabled.jvm");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.nodejs, "!configuration.auto_instrumentation_disabled.nodejs");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.python, "!configuration.auto_instrumentation_disabled.python");
}

test "hasAllowedPrefix: default OTEL_ prefix only" {
    try test_util.expectWithMessage(
        hasAllowedPrefix("OTEL_SDK_DISABLED", "OTEL_"),
        "OTEL_SDK_DISABLED should match OTEL_",
    );
    try test_util.expectWithMessage(
        !hasAllowedPrefix("CUSTOM_PREFIX_ACCESS_TOKEN", "OTEL_"),
        "CUSTOM_PREFIX_ACCESS_TOKEN should not match OTEL_",
    );
}

test "hasAllowedPrefix: supports multiple prefixes and whitespace" {
    try test_util.expectWithMessage(
        hasAllowedPrefix("OTEL_SDK_DISABLED", " OTEL_ , CUSTOM_PREFIX_ ,, VENDOR_ "),
        "OTEL_SDK_DISABLED should match OTEL_",
    );
    try test_util.expectWithMessage(
        hasAllowedPrefix("CUSTOM_PREFIX_ACCESS_TOKEN", " OTEL_ , CUSTOM_PREFIX_ ,, VENDOR_ "),
        "CUSTOM_PREFIX_ACCESS_TOKEN should match CUSTOM_PREFIX_",
    );
    try test_util.expectWithMessage(
        hasAllowedPrefix("VENDOR_TRACE_MODE", " OTEL_ , CUSTOM_PREFIX_ ,, VENDOR_ "),
        "VENDOR_TRACE_MODE should match VENDOR_",
    );
    try test_util.expectWithMessage(
        !hasAllowedPrefix("PATH", " OTEL_ , CUSTOM_PREFIX_ ,, VENDOR_ "),
        "PATH should not match any configured prefix",
    );
}

test "readAllAgentsEnvFile: stores only variables matching allowed prefixes" {
    // Derive the sample keys from the build's configured allowed prefixes so this test
    // stays correct regardless of the -Dallowed-env-var-prefixes value it was built with.
    const allowed_key = comptime blk: {
        var prefixes = std.mem.splitScalar(u8, build_options.allowed_env_var_prefixes, ',');
        while (prefixes.next()) |raw_prefix| {
            const prefix = std.mem.trim(u8, raw_prefix, " \t\r\n");
            if (prefix.len == 0) continue;
            break :blk prefix ++ "TEST_ALLOWED_KEY";
        }
        @compileError("build has no non-empty allowed_env_var_prefixes");
    };
    const disallowed_key = comptime blk: {
        // Pick a sentinel key that provably does not match any configured prefix.
        const candidates = [_][]const u8{
            "ZZZ_TEST_DISALLOWED_KEY",
            "QQQ_TEST_DISALLOWED_KEY",
            "JJJ_TEST_DISALLOWED_KEY",
        };
        for (candidates) |c| {
            if (!hasAllowedPrefix(c, build_options.allowed_env_var_prefixes)) {
                break :blk c;
            }
        }
        @compileError("could not find a sentinel disallowed key for this build's allowed_env_var_prefixes");
    };

    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    {
        const file = try tmp_dir.dir.createFile(testing.io, "default_env.conf", .{});
        defer file.close(testing.io);
        try file.writeStreamingAll(testing.io, allowed_key ++ "=allowed-value\n" ++ disallowed_key ++ "=disallowed-value\n");
    }

    const absolute_path_to_env_file = try tmp_dir.dir.realPathFileAlloc(testing.io, "default_env.conf", allocator);
    defer allocator.free(absolute_path_to_env_file);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var configuration = try createDefaultConfiguration(arena_allocator);
    readAllAgentsEnvFile(testing.io, arena_allocator, absolute_path_to_env_file, &configuration);

    try testing.expectEqual(1, configuration.all_auto_instrumentation_agents_env_vars.count());
    try testing.expectEqualStrings(
        "allowed-value",
        configuration.all_auto_instrumentation_agents_env_vars.get(allowed_key).?,
    );
    try test_util.expectWithMessage(
        configuration.all_auto_instrumentation_agents_env_vars.get(disallowed_key) == null,
        "key with disallowed prefix should not be loaded",
    );
}

/// Unquotes a configuration value using shell-style quoting rules for the
/// well-formed cases, with a deliberate divergence from bash for malformed
/// input (see the "not shell-standard" note below).
///
/// - Values wrapped in matching `"..."`: the outer quotes are stripped and backslash
///   escapes are processed only for `\"`, `\\`, `\$`, and `` \` `` — the backslash
///   is consumed and the next character is kept. Any other `\<c>` is preserved
///   verbatim (both the backslash and `c`), which matches bash's behavior inside
///   double quotes: `"\n"`, `"\t"`, `"\z"` all stay literal two-character sequences.
/// - Values wrapped in matching `'...'`: the outer quotes are stripped and no
///   escape processing is performed. This matches bash single-quote semantics
///   (a `'` cannot appear inside single quotes at all).
/// - Values without matching surrounding quotes are returned unchanged. THIS IS
///   NOT SHELL-STANDARD: bash would either report a syntax error or continue
///   reading additional lines looking for a matching closing quote. This parser
///   is line-oriented and does neither. Instead, parseLine emits a warning via
///   `hasUnbalancedQuotes` so the user can spot the typo, and passes the value
///   through literally rather than silently dropping the line.
///
/// May allocate on the arena when escape processing shortens the value.
fn unquoteValue(arena_allocator: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]u8 {
    if (value.len >= 2) {
        const first = value[0];
        const last = value[value.len - 1];
        if (first == last and (first == '"' or first == '\'')) {
            const inner = value[1 .. value.len - 1];
            if (first == '\'') {
                return arena_allocator.dupe(u8, inner);
            }
            // Double-quoted: fast path when there are no backslashes to process.
            if (std.mem.indexOfScalar(u8, inner, '\\') == null) {
                return arena_allocator.dupe(u8, inner);
            }
            // Two-pass: compute the final length first so the returned slice
            // length matches the underlying allocation exactly. That keeps
            // callers using a GPA (e.g. tests) able to free the value cleanly.
            var final_len: usize = 0;
            var i: usize = 0;
            while (i < inner.len) : (i += 1) {
                if (isEscapedByBackslash(inner, i)) {
                    i += 1;
                }
                final_len += 1;
            }
            const buf = try arena_allocator.alloc(u8, final_len);
            var w: usize = 0;
            i = 0;
            while (i < inner.len) : (i += 1) {
                if (isEscapedByBackslash(inner, i)) {
                    buf[w] = inner[i + 1];
                    w += 1;
                    i += 1;
                    continue;
                }
                buf[w] = inner[i];
                w += 1;
            }
            return buf;
        }
    }
    return arena_allocator.dupe(u8, value);
}

fn isEscapedByBackslash(inner: []const u8, i: usize) bool {
    if (inner[i] != '\\' or i + 1 >= inner.len) return false;
    const next = inner[i + 1];
    return next == '"' or next == '\\' or next == '$' or next == '`';
}

/// Reports whether a raw value (as read from a config line, after whitespace
/// trimming and before unquoteValue) contains quote characters that do not
/// form a well-formed pair. Intended to catch user typos like `KEY="value`,
/// `KEY=value"`, or `KEY=va"lue`.
///
/// This exists precisely because the parser diverges from shell semantics
/// for malformed input: a shell would refuse to parse `KEY="value` (or keep
/// reading until it finds a closing quote on a later line), but this parser
/// is line-oriented and accepts the value literally. The warning surfaces
/// that divergence so users can spot the mistake instead of only finding
/// out when the downstream process rejects the injected env var.
fn hasUnbalancedQuotes(value: []const u8) bool {
    if (value.len >= 2) {
        const first = value[0];
        const last = value[value.len - 1];
        if (first == last and (first == '"' or first == '\'')) {
            const inner = value[1 .. value.len - 1];
            if (first == '"') {
                // Inside a double-quoted value, any unescaped " is stray.
                var i: usize = 0;
                while (i < inner.len) : (i += 1) {
                    if (isEscapedByBackslash(inner, i)) {
                        i += 1;
                        continue;
                    }
                    if (inner[i] == '"') return true;
                }
                return false;
            }
            // Inside a single-quoted value, any ' is stray (bash cannot
            // escape ' inside '...').
            return std.mem.indexOfScalar(u8, inner, '\'') != null;
        }
    }
    // No matching outer pair: any quote character in the value is stray.
    return std.mem.indexOfAny(u8, value, "\"'") != null;
}

test "hasUnbalancedQuotes: balanced values" {
    try testing.expectEqual(false, hasUnbalancedQuotes(""));
    try testing.expectEqual(false, hasUnbalancedQuotes("plain"));
    try testing.expectEqual(false, hasUnbalancedQuotes("\"quoted\""));
    try testing.expectEqual(false, hasUnbalancedQuotes("'quoted'"));
    try testing.expectEqual(false, hasUnbalancedQuotes("\"\""));
    try testing.expectEqual(false, hasUnbalancedQuotes("''"));
    // Escaped double quotes inside a double-quoted value are balanced.
    try testing.expectEqual(false, hasUnbalancedQuotes("\"he said \\\"hi\\\"\""));
    // Escaped backslash before an unrelated char is balanced.
    try testing.expectEqual(false, hasUnbalancedQuotes("\"a\\\\b\""));
    // Single quotes inside a double-quoted value are fine.
    try testing.expectEqual(false, hasUnbalancedQuotes("\"don't\""));
    // Double quotes inside a single-quoted value are fine.
    try testing.expectEqual(false, hasUnbalancedQuotes("'he said \"hi\"'"));
}

test "hasUnbalancedQuotes: stray or unmatched quotes" {
    // Unmatched leading double quote.
    try testing.expectEqual(true, hasUnbalancedQuotes("\"value"));
    // Unmatched trailing double quote.
    try testing.expectEqual(true, hasUnbalancedQuotes("value\""));
    // Interior double quote in an otherwise unquoted value.
    try testing.expectEqual(true, hasUnbalancedQuotes("va\"lue"));
    // Unmatched leading single quote (typical: apostrophe in unquoted word).
    try testing.expectEqual(true, hasUnbalancedQuotes("don't"));
    // Mismatched quote types on the outside.
    try testing.expectEqual(true, hasUnbalancedQuotes("\"value'"));
    try testing.expectEqual(true, hasUnbalancedQuotes("'value\""));
    // Single stray character.
    try testing.expectEqual(true, hasUnbalancedQuotes("\""));
    try testing.expectEqual(true, hasUnbalancedQuotes("'"));
    // Double-quoted value with unescaped " inside.
    try testing.expectEqual(true, hasUnbalancedQuotes("\"\"nested\"\""));
    // Single-quoted value with a ' inside (bash cannot escape ' in '...').
    try testing.expectEqual(true, hasUnbalancedQuotes("'don\\'t'"));
}

/// Parses a single line from a configuration file.
/// Returns a key-value pair if the line is a valid key-value pair, and null for empty
/// lines, comments and invalid lines.
fn parseLine(arena_allocator: std.mem.Allocator, line: []u8, cfg_file_path: []const u8) ?struct {
    key: []const u8,
    value: []u8,
} {
    var l = line;
    if (std.mem.indexOfScalar(u8, l, '#')) |commentStartIdx| {
        // strip end-of-line comment (might be the whole line if the line starts with #)
        l = l[0..commentStartIdx];
    }

    const trimmed = std.mem.trim(u8, l, " \t\r\n");
    if (trimmed.len == 0) {
        // ignore empty lines or lines that only contain whitespace
        return null;
    }

    if (std.mem.indexOfScalar(u8, trimmed, '=')) |equalsIdx| {
        const key_trimmed = std.mem.trim(u8, trimmed[0..equalsIdx], " \t\r\n");
        const key = std.fmt.allocPrint(arena_allocator, "{s}", .{key_trimmed}) catch |err| {
            print.printError("error in allocPrint while allocating key from file {s}: {}", .{ cfg_file_path, err });
            return null;
        };
        const value_trimmed = std.mem.trim(u8, trimmed[equalsIdx + 1 ..], " \t\r\n");
        if (hasUnbalancedQuotes(value_trimmed)) {
            // Divergence from shell semantics: bash would refuse to parse this
            // (or keep reading additional lines looking for a matching closing
            // quote). This parser is line-oriented, so it uses the value as-is
            // and warns instead of failing.
            print.printWarn(
                "value for key \"{s}\" in {s} contains unbalanced or unquoted quote characters and will be used literally: {s}",
                .{ key, cfg_file_path, value_trimmed },
            );
        }
        const value = unquoteValue(arena_allocator, value_trimmed) catch |err| {
            print.printError("error while allocating value from file {s}: {}", .{ cfg_file_path, err });
            return null;
        };
        return .{
            .key = key,
            .value = value,
        };
    } else {
        // ignore malformed lines
        print.printError("cannot parse line in {s}: \"{s}\"", .{ cfg_file_path, line });
        return null;
    }
}

test "parseLine: empty line" {
    const allocator = testing.allocator;
    const result = parseLine(
        allocator,
        "",
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result == null, "parseLine(\"\") returns null");
}

test "parseLine: whitespace only" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "  \t ", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result == null, "parseLine(whitespace) returns null");
}

test "parseLine: full line comment" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "# this is a comment", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result == null, "parseLine(full line comment) returns null");
}

test "parseLine: end of line comment" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "key=value # comment", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(end-of-line comment) returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("key", kv.key);
        try testing.expectEqualStrings("value", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

test "parseLine: valid key-value pair for unknown key" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "key=value", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(key-value pair/unknown key) returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("key", kv.key);
        try testing.expectEqualStrings("value", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

test "parseLine: valid key-value pair for known key" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "jvm_auto_instrumentation_agent_path=/custom/path/to/jvm/agent", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(key-value pair/known key) returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("jvm_auto_instrumentation_agent_path", kv.key);
        try testing.expectEqualStrings("/custom/path/to/jvm/agent", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

test "parseLine: valid key-value pair for known key with end-of-line comment" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "jvm_auto_instrumentation_agent_path=/custom/path/to/jvm/agent # comment", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(key-value pair/known key/eol comment) returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("jvm_auto_instrumentation_agent_path", kv.key);
        try testing.expectEqualStrings("/custom/path/to/jvm/agent", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

test "parseLine: valid key-value pair with whitespace" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "  jvm_auto_instrumentation_agent_path \t =  /custom/path/to/jvm/agent  ", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(key-value pair/known key/whitespace) returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("jvm_auto_instrumentation_agent_path", kv.key);
        try testing.expectEqualStrings("/custom/path/to/jvm/agent", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

test "parseLine: multiple equals characters" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "jvm_auto_instrumentation_agent_path=/path/with/=/character/===", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(key-value pair/known key/multiple equals) returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("jvm_auto_instrumentation_agent_path", kv.key);
        try testing.expectEqualStrings("/path/with/=/character/===", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

test "parseLine: invalid line (no = character)" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "this line is invalid", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result == null, "parseLine(invalid line) returns null");
}

test "parseLine: invalid line (line too long)" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "this line is invalid", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result == null, "parseLine(invalid line) returns null");
}

test "parseLine: strips surrounding double quotes from value" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "OTEL_EXPORTER_OTLP_PROTOCOL=\"http/protobuf\"", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(double-quoted value) returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("OTEL_EXPORTER_OTLP_PROTOCOL", kv.key);
        try testing.expectEqualStrings("http/protobuf", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

test "parseLine: strips surrounding single quotes from value" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "OTEL_EXPORTER_OTLP_ENDPOINT='https://example.com'", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(single-quoted value) returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("OTEL_EXPORTER_OTLP_ENDPOINT", kv.key);
        try testing.expectEqualStrings("https://example.com", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

test "parseLine: strips surrounding quotes around whitespace" {
    const allocator = testing.allocator;
    // Whitespace inside the quotes must be preserved, only whitespace outside the
    // quotes is trimmed.
    const line = try std.fmt.allocPrint(allocator, "  key  =  \"  value with spaces  \"  ", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(quoted value with padding) returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("key", kv.key);
        try testing.expectEqualStrings("  value with spaces  ", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

test "parseLine: preserves inner quotes and only strips one surrounding pair" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "key=\"\"nested\"\"", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(nested quotes) returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("key", kv.key);
        try testing.expectEqualStrings("\"nested\"", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

test "parseLine: preserves unbalanced quotes" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "key=\"unbalanced", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(unbalanced quote) returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("key", kv.key);
        try testing.expectEqualStrings("\"unbalanced", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

test "parseLine: preserves mismatched quote characters" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "key=\"mismatched'", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(mismatched quote types) returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("key", kv.key);
        try testing.expectEqualStrings("\"mismatched'", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

test "parseLine: empty double-quoted value becomes empty string" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "key=\"\"", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(empty quoted value) returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("key", kv.key);
        try testing.expectEqualStrings("", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

test "parseLine: single quote character is preserved" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "key=\"", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(single quote char) returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("key", kv.key);
        try testing.expectEqualStrings("\"", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

test "parseLine: quoted value with commas is preserved verbatim" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "OTEL_EXPORTER_OTLP_HEADERS=\"Authorization=Bearer%20abc,Custom-Header=value\"", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(quoted headers) returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("OTEL_EXPORTER_OTLP_HEADERS", kv.key);
        try testing.expectEqualStrings("Authorization=Bearer%20abc,Custom-Header=value", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

test "parseLine: empty single-quoted value" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "key=''", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(empty single-quoted) returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("key", kv.key);
        try testing.expectEqualStrings("", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

test "parseLine: unbalanced single quote is preserved" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "key='unbalanced", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(unbalanced single quote) returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("key", kv.key);
        try testing.expectEqualStrings("'unbalanced", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

// --- Double-quoted escape processing ---

test "parseLine: double quote escapes an inner double quote" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "key=\"a\\\"b\"", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(\\\") returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("key", kv.key);
        try testing.expectEqualStrings("a\"b", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

test "parseLine: double quote escapes a backslash" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "key=\"a\\\\b\"", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(\\\\) returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("key", kv.key);
        try testing.expectEqualStrings("a\\b", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

test "parseLine: double quote escapes a dollar sign" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "key=\"a\\$b\"", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(\\$) returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("key", kv.key);
        try testing.expectEqualStrings("a$b", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

test "parseLine: double quote escapes a backtick" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "key=\"a\\`b\"", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(\\`) returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("key", kv.key);
        try testing.expectEqualStrings("a`b", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

test "parseLine: double-quoted \\n is a literal two-character sequence" {
    // Matches bash: \n inside double quotes is NOT a newline.
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "key=\"a\\nb\"", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(\\n literal) returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("key", kv.key);
        try testing.expectEqualStrings("a\\nb", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

test "parseLine: double-quoted \\t is a literal two-character sequence" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "key=\"a\\tb\"", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(\\t literal) returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("key", kv.key);
        try testing.expectEqualStrings("a\\tb", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

test "parseLine: double-quoted unknown escape stays literal" {
    // Bash: \<c> for c not in {$, `, \", \\, newline} keeps both chars.
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "key=\"a\\zb\"", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(\\z literal) returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("key", kv.key);
        try testing.expectEqualStrings("a\\zb", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

test "parseLine: escaped quote as sole content produces a single quote character" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "key=\"\\\"\"", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(escaped quote only) returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("key", kv.key);
        try testing.expectEqualStrings("\"", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

test "parseLine: mixed escapes \\\\ then \\\"" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "key=\"\\\\\\\"\"", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(\\\\\\\") returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("key", kv.key);
        try testing.expectEqualStrings("\\\"", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

// --- Single-quoted values: no escape processing ---

test "parseLine: single-quoted backslash-quote is literal" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "key='a\\\"b'", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(single-quoted \\\") returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("key", kv.key);
        try testing.expectEqualStrings("a\\\"b", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

test "parseLine: single-quoted double backslash is literal" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "key='a\\\\b'", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(single-quoted \\\\) returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("key", kv.key);
        try testing.expectEqualStrings("a\\\\b", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

test "parseLine: single-quoted dollar sign is literal" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "key='a$b'", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(single-quoted $) returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("key", kv.key);
        try testing.expectEqualStrings("a$b", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

test "parseLine: single-quoted backslash-n is literal" {
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "key='a\\nb'", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(single-quoted \\n literal) returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("key", kv.key);
        try testing.expectEqualStrings("a\\nb", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

// --- Trailing-backslash edge cases (bash would treat these as unmatched
//     quotes / line continuation; a line-oriented parser cannot, so we keep
//     the backslash literal). ---

test "parseLine: unquoted value with interior double quote is preserved literally" {
    // This should also emit a warning, but the parser still returns the value
    // rather than dropping it — losing a line silently would be worse than
    // passing through a possibly-mistyped value.
    const allocator = testing.allocator;
    const line = try std.fmt.allocPrint(allocator, "a=b\"c", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(interior stray quote) returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("a", kv.key);
        try testing.expectEqualStrings("b\"c", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

test "parseLine: trailing backslash inside double quotes is literal" {
    const allocator = testing.allocator;
    // The inner content after stripping outer quotes is `a\`. The trailing
    // backslash has no following character to escape, so it stays literal.
    const line = try std.fmt.allocPrint(allocator, "key=\"a\\\"", .{});
    defer allocator.free(line);
    const result = parseLine(
        allocator,
        line,
        "/path/to/configuration",
    );
    try test_util.expectWithMessage(result != null, "parseLine(trailing backslash) returns key-value");
    if (result) |kv| {
        try testing.expectEqualStrings("key", kv.key);
        try testing.expectEqualStrings("a\\", kv.value);
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

fn readConfigurationFromEnvironment(io: std.Io, arena_allocator: std.mem.Allocator, configuration: *InjectorConfiguration, getenv_fn: proc_self_environ_parser.GetenvFn) void {
    inline for (options.file_options) |option| {
        if (comptime option.env_name != null) {
            if (getenv_fn(io, arena_allocator, option.env_name.?)) |raw| {
                const parsed: ?@TypeOf(option).ValueType = option.parseEnvironment(arena_allocator, raw) catch |err| blk: {
                    if (err == error.InvalidValue) {
                        option.warnInvalidValue(raw, option.env_name.?);
                        break :blk null;
                    }
                    print.printError("Cannot allocate memory to read the injector configuration from the environment: {}", .{err});
                    return;
                };
                if (parsed) |resolved| @field(configuration, option.file_key.?) = resolved;
            }
        }
    }
}

test "readConfigurationFromEnvironment: allocation failure stops remaining overrides" {
    inline for (.{ options.dotnet_agent_path, options.include_paths }) |option| {
        const Env = struct {
            var value_read = false;
            var read_after_failure = false;

            fn read(_: std.Io, _: std.mem.Allocator, name: []const u8) ?[]u8 {
                if (value_read) read_after_failure = true;
                if (std.mem.eql(u8, name, option.env_name.?)) {
                    value_read = true;
                    return @constCast("/configured/agent");
                }
                return null;
            }
        };
        var configuration = createEmptyConfiguration(testing.failing_allocator);
        defer configuration.deinit(testing.failing_allocator);
        readConfigurationFromEnvironment(testing.io, testing.failing_allocator, &configuration, Env.read);

        try testing.expect(Env.value_read);
        try testing.expect(!Env.read_after_failure);
        try testing.expectEqual(@as(usize, 0), @field(configuration, option.file_key.?).len);
    }
}

test "readConfigurationFromEnvironment: empty overrides clear settings and invalid integers retain file values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const original_environ = try test_util.setStdCEnviron(&.{
        "JVM_AUTO_INSTRUMENTATION_AGENT_PATH=",
        "OTEL_INJECTOR_INCLUDE_PATHS=",
        "OTEL_INJECTOR_AUTO_INSTRUMENTATION_DISABLED=",
        "DOTNET_AUTO_INSTRUMENTATION_MINIMUM_DOTNET_MAJOR_VERSION=invalid",
    });
    defer test_util.resetStdCEnviron(original_environ);

    var configuration = try createDefaultConfiguration(allocator);
    configuration.jvm_auto_instrumentation_agent_path = @constCast("/configured/agent.jar");
    configuration.include_paths = try options.include_paths.parse(allocator, "/app/*", "test");
    configuration.auto_instrumentation_disabled = .{ .jvm = true, .ruby = true };
    configuration.dotnet_auto_instrumentation_minimum_dotnet_major_version = 6;
    readConfigurationFromEnvironment(testing.io, allocator, &configuration, test_util.posixGetenv);

    try testing.expectEqualStrings("", configuration.jvm_auto_instrumentation_agent_path);
    try testing.expectEqual(@as(usize, 0), configuration.include_paths.len);
    try testing.expectEqualDeep(options.auto_instrumentation_disabled.initialValue(), configuration.auto_instrumentation_disabled);
    try testing.expectEqual(@as(u32, 6), configuration.dotnet_auto_instrumentation_minimum_dotnet_major_version);
}

test "readConfigurationFromEnvironment: empty environment values" {
    const allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const original_environ = try test_util.clearStdCEnviron();
    defer test_util.resetStdCEnviron(original_environ);

    var configuration = try createDefaultConfiguration(arena_allocator);
    readConfigurationFromEnvironment(testing.io, arena_allocator, &configuration, test_util.posixGetenv);

    try testing.expectEqualStrings(
        "",
        configuration.dotnet_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        "",
        configuration.jvm_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        "",
        configuration.nodejs_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        "",
        configuration.python_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        "/etc/opentelemetry/injector/default_env.conf",
        configuration.all_auto_instrumentation_agents_env_path,
    );
    try testing.expectEqual(0, configuration.include_paths.len);
    try testing.expectEqual(0, configuration.exclude_paths.len);
    try testing.expectEqual(0, configuration.include_with_arguments.len);
    try testing.expectEqual(0, configuration.exclude_with_arguments.len);
}

test "readConfigurationFromEnvironment: all values" {
    const allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const original_environ = try test_util.setStdCEnviron(&[9][]const u8{
        "DOTNET_AUTO_INSTRUMENTATION_AGENT_PATH_PREFIX=/path/from/env/var/dotnet",
        "DOTNET_AUTO_INSTRUMENTATION_MINIMUM_DOTNET_MAJOR_VERSION=6",
        "JVM_AUTO_INSTRUMENTATION_AGENT_PATH=/path/from/env/var/jvm",
        "NODEJS_AUTO_INSTRUMENTATION_AGENT_PATH=/path/from/env/var/nodejs",
        "PYTHON_AUTO_INSTRUMENTATION_AGENT_PATH_PREFIX=/path/from/env/var/python",
        "OTEL_INJECTOR_INCLUDE_PATHS=/path/from/env/var/include1,/path/from/env/var/include2",
        "OTEL_INJECTOR_EXCLUDE_PATHS=/path/from/env/var/exclude1,/path/from/env/var/exclude2",
        "OTEL_INJECTOR_INCLUDE_WITH_ARGUMENTS=--from-env-var-include1,--from-env-var-include2",
        "OTEL_INJECTOR_EXCLUDE_WITH_ARGUMENTS=--from-env-var-exclude1,--from-env-var-exclude2",
    });
    defer test_util.resetStdCEnviron(original_environ);

    var configuration = try createDefaultConfiguration(arena_allocator);
    readConfigurationFromEnvironment(testing.io, arena_allocator, &configuration, test_util.posixGetenv);

    try testing.expectEqualStrings(
        "/path/from/env/var/dotnet",
        configuration.dotnet_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqual(@as(u32, 6), configuration.dotnet_auto_instrumentation_minimum_dotnet_major_version);
    try testing.expectEqualStrings(
        "/path/from/env/var/jvm",
        configuration.jvm_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        "/path/from/env/var/nodejs",
        configuration.nodejs_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        "/path/from/env/var/python",
        configuration.python_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        "/etc/opentelemetry/injector/default_env.conf",
        configuration.all_auto_instrumentation_agents_env_path,
    );
    try testing.expectEqual(2, configuration.include_paths.len);
    try testing.expectEqualStrings("/path/from/env/var/include1", configuration.include_paths[0]);
    try testing.expectEqualStrings("/path/from/env/var/include2", configuration.include_paths[1]);
    try testing.expectEqual(2, configuration.exclude_paths.len);
    try testing.expectEqualStrings("/path/from/env/var/exclude1", configuration.exclude_paths[0]);
    try testing.expectEqualStrings("/path/from/env/var/exclude2", configuration.exclude_paths[1]);
    try testing.expectEqual(2, configuration.include_with_arguments.len);
    try testing.expectEqualStrings("--from-env-var-include1", configuration.include_with_arguments[0]);
    try testing.expectEqualStrings("--from-env-var-include2", configuration.include_with_arguments[1]);
    try testing.expectEqual(2, configuration.exclude_with_arguments.len);
    try testing.expectEqualStrings("--from-env-var-exclude1", configuration.exclude_with_arguments[0]);
    try testing.expectEqualStrings("--from-env-var-exclude2", configuration.exclude_with_arguments[1]);
}

test "readConfigurationFromEnvironment: OTEL_INJECTOR_AUTO_INSTRUMENTATION_DISABLED=* disables all runtimes" {
    const allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const original_environ = try test_util.setStdCEnviron(&[1][]const u8{
        "OTEL_INJECTOR_AUTO_INSTRUMENTATION_DISABLED=*",
    });
    defer test_util.resetStdCEnviron(original_environ);

    var configuration = try createDefaultConfiguration(arena_allocator);
    readConfigurationFromEnvironment(testing.io, arena_allocator, &configuration, test_util.posixGetenv);

    try test_util.expectWithMessage(configuration.auto_instrumentation_disabled.dotnet, "configuration.auto_instrumentation_disabled.dotnet");
    try test_util.expectWithMessage(configuration.auto_instrumentation_disabled.jvm, "configuration.auto_instrumentation_disabled.jvm");
    try test_util.expectWithMessage(configuration.auto_instrumentation_disabled.nodejs, "configuration.auto_instrumentation_disabled.nodejs");
    try test_util.expectWithMessage(configuration.auto_instrumentation_disabled.python, "configuration.auto_instrumentation_disabled.python");
}

test "readConfigurationFromEnvironment: OTEL_INJECTOR_AUTO_INSTRUMENTATION_DISABLED with specific runtimes" {
    const allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const original_environ = try test_util.setStdCEnviron(&[1][]const u8{
        "OTEL_INJECTOR_AUTO_INSTRUMENTATION_DISABLED=nodejs,python",
    });
    defer test_util.resetStdCEnviron(original_environ);

    var configuration = try createDefaultConfiguration(arena_allocator);
    readConfigurationFromEnvironment(testing.io, arena_allocator, &configuration, test_util.posixGetenv);

    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.dotnet, "!configuration.auto_instrumentation_disabled.dotnet");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.jvm, "!configuration.auto_instrumentation_disabled.jvm");
    try test_util.expectWithMessage(configuration.auto_instrumentation_disabled.nodejs, "configuration.auto_instrumentation_disabled.nodejs");
    try test_util.expectWithMessage(configuration.auto_instrumentation_disabled.python, "configuration.auto_instrumentation_disabled.python");
}

test "readConfigurationFromEnvironment: OTEL_INJECTOR_AUTO_INSTRUMENTATION_DISABLED with all runtimes individually" {
    const allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const original_environ = try test_util.setStdCEnviron(&[1][]const u8{
        "OTEL_INJECTOR_AUTO_INSTRUMENTATION_DISABLED=dotnet,jvm,nodejs,python",
    });
    defer test_util.resetStdCEnviron(original_environ);

    var configuration = try createDefaultConfiguration(arena_allocator);
    readConfigurationFromEnvironment(testing.io, arena_allocator, &configuration, test_util.posixGetenv);

    try test_util.expectWithMessage(configuration.auto_instrumentation_disabled.dotnet, "configuration.auto_instrumentation_disabled.dotnet");
    try test_util.expectWithMessage(configuration.auto_instrumentation_disabled.jvm, "configuration.auto_instrumentation_disabled.jvm");
    try test_util.expectWithMessage(configuration.auto_instrumentation_disabled.nodejs, "configuration.auto_instrumentation_disabled.nodejs");
    try test_util.expectWithMessage(configuration.auto_instrumentation_disabled.python, "configuration.auto_instrumentation_disabled.python");
}

test "readConfigurationFromEnvironment: OTEL_INJECTOR_AUTO_INSTRUMENTATION_DISABLED with unknown runtime is ignored" {
    const allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const original_environ = try test_util.setStdCEnviron(&[1][]const u8{
        "OTEL_INJECTOR_AUTO_INSTRUMENTATION_DISABLED=nodejs,unknown,nodejs",
    });
    defer test_util.resetStdCEnviron(original_environ);

    var configuration = try createDefaultConfiguration(arena_allocator);
    readConfigurationFromEnvironment(testing.io, arena_allocator, &configuration, test_util.posixGetenv);

    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.dotnet, "!configuration.auto_instrumentation_disabled.dotnet");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.jvm, "!configuration.auto_instrumentation_disabled.jvm");
    try test_util.expectWithMessage(configuration.auto_instrumentation_disabled.nodejs, "configuration.auto_instrumentation_disabled.nodejs");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.python, "!configuration.auto_instrumentation_disabled.python");
}

test "readConfigurationFromEnvironment: if OTEL_INJECTOR_AUTO_INSTRUMENTATION_DISABLED is not set, all runtimes are enabled" {
    const allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const original_environ = try test_util.clearStdCEnviron();
    defer test_util.resetStdCEnviron(original_environ);

    var configuration = try createDefaultConfiguration(arena_allocator);
    readConfigurationFromEnvironment(testing.io, arena_allocator, &configuration, test_util.posixGetenv);

    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.dotnet, "!configuration.auto_instrumentation_disabled.dotnet");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.jvm, "!configuration.auto_instrumentation_disabled.jvm");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.nodejs, "!configuration.auto_instrumentation_disabled.nodejs");
    try test_util.expectWithMessage(!configuration.auto_instrumentation_disabled.python, "!configuration.auto_instrumentation_disabled.python");
}

test "readConfigurationDirectory: directory does not exist" {
    const allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const original_environ = try test_util.setStdCEnviron(&[1][]const u8{
        "OTEL_INJECTOR_CONFIG_DIR=/does/not/exist",
    });
    defer test_util.resetStdCEnviron(original_environ);

    var configuration = try createDefaultConfiguration(arena_allocator);
    readConfigurationDirectory(testing.io, arena_allocator, &configuration, test_util.posixGetenv);

    // Configuration should remain at defaults when the directory does not exist.
    try testing.expectEqualStrings(
        "",
        configuration.dotnet_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        "",
        configuration.jvm_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        "",
        configuration.nodejs_auto_instrumentation_agent_path,
    );
}

test "readConfigurationDirectory: reads .conf files in alphabetical order and ignores non-.conf files" {
    const allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const original_environ = try test_util.setStdCEnviron(&[1][]const u8{
        "OTEL_INJECTOR_CONFIG_DIR=unit-test-assets/config/conf.d",
    });
    defer test_util.resetStdCEnviron(original_environ);

    var configuration = try createDefaultConfiguration(arena_allocator);
    readConfigurationDirectory(testing.io, arena_allocator, &configuration, test_util.posixGetenv);

    // 01-java.conf sets the JVM path
    try testing.expectEqualStrings(
        "/conf.d/path/to/jvm/javaagent.jar",
        configuration.jvm_auto_instrumentation_agent_path,
    );
    // 02-nodejs.conf sets the Node.js path
    try testing.expectEqualStrings(
        "/conf.d/path/to/nodejs/register.js",
        configuration.nodejs_auto_instrumentation_agent_path,
    );
    // not-a-conf-file.txt should be ignored, so the dotnet path should remain at the default.
    try testing.expectEqualStrings(
        "",
        configuration.dotnet_auto_instrumentation_agent_path_prefix,
    );
}

test "readConfigurationDirectory: conf.d files override values from the main configuration file" {
    const allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const original_environ = try test_util.setStdCEnviron(&[1][]const u8{
        "OTEL_INJECTOR_CONFIG_DIR=unit-test-assets/config/conf.d",
    });
    defer test_util.resetStdCEnviron(original_environ);

    // First set a JVM path from the main config, then apply conf.d which should override it.
    var configuration = try createDefaultConfiguration(arena_allocator);
    configuration.jvm_auto_instrumentation_agent_path = @constCast("/original/jvm/path.jar");
    readConfigurationDirectory(testing.io, arena_allocator, &configuration, test_util.posixGetenv);

    try testing.expectEqualStrings(
        "/conf.d/path/to/jvm/javaagent.jar",
        configuration.jvm_auto_instrumentation_agent_path,
    );
}

fn copyMap(allocator: std.mem.Allocator, source: std.StringHashMap([]u8)) !std.StringHashMap([]u8) {
    var target = std.StringHashMap([]u8).init(allocator);
    errdefer {
        var it = target.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        target.deinit();
    }
    try target.ensureTotalCapacity(source.count());
    var it = source.iterator();
    while (it.next()) |entry| {
        const key = try std.fmt.allocPrint(allocator, "{s}", .{entry.key_ptr.*});
        errdefer allocator.free(key);
        const value = try std.fmt.allocPrint(allocator, "{s}", .{entry.value_ptr.*});
        errdefer allocator.free(value);
        try target.put(key, value);
    }
    return target;
}
