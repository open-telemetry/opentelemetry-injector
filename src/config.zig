// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const print = @import("print.zig");
const test_util = @import("test_util.zig");
const patterns_util = @import("patterns_util.zig");

const testing = std.testing;

const default_config_file_path = "/etc/opentelemetry/otelinject.conf";
const config_file_path_env_var = "OTEL_INJECTOR_CONFIG_FILE";
const max_line_length = 8192;
const empty_string = @constCast("");
const otel_env_var_prefix = "OTEL_";

const dotnet_path_key = "dotnet_auto_instrumentation_agent_path_prefix";
const jvm_path_key = "jvm_auto_instrumentation_agent_path";
const nodejs_path_key = "nodejs_auto_instrumentation_agent_path";

const all_agents_env_path_key = "all_auto_instrumentation_agents_env_path";

const dotnet_path_env_var = "DOTNET_AUTO_INSTRUMENTATION_AGENT_PATH_PREFIX";
const jvm_path_env_var = "JVM_AUTO_INSTRUMENTATION_AGENT_PATH";
const nodejs_path_env_var = "NODEJS_AUTO_INSTRUMENTATION_AGENT_PATH";

/// Configuration options for choosing what to instrument or exclude from instrumentation
const include_paths_key = "include_paths";
const exclude_paths_key = "exclude_paths";

const include_paths_env_var = "OTEL_INJECTOR_INCLUDE_PATHS";
const exclude_paths_env_var = "OTEL_INJECTOR_EXCLUDE_PATHS";

const include_args_key = "include_with_arguments";
const exclude_args_key = "exclude_with_arguments";

const include_args_env_var = "OTEL_INJECTOR_INCLUDE_WITH_ARGUMENTS";
const exclude_args_env_var = "OTEL_INJECTOR_EXCLUDE_WITH_ARGUMENTS";

pub const InjectorConfiguration = struct {
    dotnet_auto_instrumentation_agent_path_prefix: []u8,
    jvm_auto_instrumentation_agent_path: []u8,
    nodejs_auto_instrumentation_agent_path: []u8,
    all_auto_instrumentation_agents_env_path: []u8,
    all_auto_instrumentation_agents_env_vars: std.StringHashMap([]u8),
    include_paths: [][]const u8,
    exclude_paths: [][]const u8,
    include_args: [][]const u8,
    exclude_args: [][]const u8,

    pub fn deinit(self: *InjectorConfiguration, allocator: std.mem.Allocator) void {
        allocator.free(self.dotnet_auto_instrumentation_agent_path_prefix);
        allocator.free(self.jvm_auto_instrumentation_agent_path);
        allocator.free(self.nodejs_auto_instrumentation_agent_path);
        allocator.free(self.all_auto_instrumentation_agents_env_path);
        var it = self.all_auto_instrumentation_agents_env_vars.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.all_auto_instrumentation_agents_env_vars.deinit();
        deinitStringArray(allocator, self.include_paths);
        deinitStringArray(allocator, self.exclude_paths);
        deinitStringArray(allocator, self.include_args);
        deinitStringArray(allocator, self.exclude_args);
    }
};

const ConfigApplier = fn (gpa: std.mem.Allocator, key: []const u8, value: []u8, file_path: []const u8, configuration: *InjectorConfiguration) void;

const default_dotnet_auto_instrumentation_agent_path_prefix = "/usr/lib/opentelemetry/dotnet";
const default_jvm_auto_instrumentation_agent_path = "/usr/lib/opentelemetry/jvm/javaagent.jar";
const default_nodejs_auto_instrumentation_agent_path = "/usr/lib/opentelemetry/nodejs/node_modules/@opentelemetry/auto-instrumentations-node/build/src/register.js";

const default_all_auto_instrumentation_agents_env_path = "/etc/opentelemetry/default_auto_instrumentation_env.conf";

var cached_configuration_optional: ?InjectorConfiguration = null;

/// Checks whether the configuration has already been read and reads it if necessary. The configuration will only be
/// read once per process and the result will be cached for subsequent calls.
///
/// The configuration will be read from the path denoted by the environment variable OTEL_INJECTOR_CONFIG_FILE, or from
/// the default location /etc/opentelemetry/otelinject.conf if this environment variable is unset or empty.
/// If the file does not exist or cannot be opened, readConfiguration continues with default values.
///
/// After reading the configuration file, the configuration will be merged with values read from environment variables
/// (DOTNET_AUTO_INSTRUMENTATION_AGENT_PATH_PREFIX, JVM_AUTO_INSTRUMENTATION_AGENT_PATH, etc.). Environment variables
/// have higher precedence and can override settings from the configuration file.
pub fn readConfiguration(allocator: std.mem.Allocator) InjectorConfiguration {
    if (cached_configuration_optional) |cached_configuration| {
        return cached_configuration;
    }

    var config_file_path: []const u8 = default_config_file_path;
    if (std.posix.getenv(config_file_path_env_var)) |value| {
        config_file_path = std.mem.trim(u8, value, " \t\r\n");
        if (config_file_path.len == 0) {
            config_file_path = default_config_file_path;
        }
    }

    return readConfigurationFromPath(allocator, config_file_path) catch |err| {
        print.printError("Cannot allocate memory while parsing configuration: {t}", .{err});
        return createEmptyConfiguration(allocator);
    };
}

fn createEmptyConfiguration(allocator: std.mem.Allocator) InjectorConfiguration {
    return InjectorConfiguration{
        .dotnet_auto_instrumentation_agent_path_prefix = "",
        .jvm_auto_instrumentation_agent_path = "",
        .nodejs_auto_instrumentation_agent_path = "",
        .all_auto_instrumentation_agents_env_path = "",
        .all_auto_instrumentation_agents_env_vars = std.StringHashMap([]u8).init(allocator),
        .include_paths = &.{},
        .exclude_paths = &.{},
        .include_args = &.{},
        .exclude_args = &.{},
    };
}

fn readConfigurationFromPath(allocator: std.mem.Allocator, cfg_file_path: []const u8) std.mem.Allocator.Error!InjectorConfiguration {
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
    readConfigurationFile(arena_allocator, cfg_file_path, &preliminary_configuration);
    readConfigurationFromEnvironment(arena_allocator, &preliminary_configuration);
    readAllAgentsEnvFile(
        arena_allocator,
        preliminary_configuration.all_auto_instrumentation_agents_env_path,
        &preliminary_configuration,
    );

    const final_configuration =
        try copyToPermanentlyAllocatedHeap(allocator, preliminary_configuration);
    cached_configuration_optional = final_configuration;
    return final_configuration;
}

test "readConfigurationFromPath: file does not exist, no environment variables" {
    const allocator = testing.allocator;

    const original_environ = try test_util.clearStdCEnviron();
    defer test_util.resetStdCEnviron(original_environ);

    var configuration = try readConfigurationFromPath(allocator, @constCast("/does/not/exist"));
    defer configuration.deinit(allocator);

    try testing.expectEqualStrings(
        default_dotnet_auto_instrumentation_agent_path_prefix,
        configuration.dotnet_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        default_jvm_auto_instrumentation_agent_path,
        configuration.jvm_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        default_nodejs_auto_instrumentation_agent_path,
        configuration.nodejs_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        default_all_auto_instrumentation_agents_env_path,
        configuration.all_auto_instrumentation_agents_env_path,
    );
    try testing.expectEqual(0, configuration.all_auto_instrumentation_agents_env_vars.count());
    try testing.expectEqual(0, configuration.include_paths.len);
    try testing.expectEqual(0, configuration.exclude_paths.len);
    try testing.expectEqual(0, configuration.include_args.len);
    try testing.expectEqual(0, configuration.exclude_args.len);
}

test "readConfigurationFromPath: file does not exist, environment variables are set" {
    const allocator = testing.allocator;

    const original_environ = try test_util.setStdCEnviron(&[7][]const u8{
        "DOTNET_AUTO_INSTRUMENTATION_AGENT_PATH_PREFIX=/path/from/env/var/dotnet",
        "JVM_AUTO_INSTRUMENTATION_AGENT_PATH=/path/from/env/var/jvm",
        "NODEJS_AUTO_INSTRUMENTATION_AGENT_PATH=/path/from/env/var/nodejs",
        "OTEL_INJECTOR_INCLUDE_PATHS=/path/from/env/var/include1,/path/from/env/var/include2",
        "OTEL_INJECTOR_EXCLUDE_PATHS=/path/from/env/var/exclude1,/path/from/env/var/exclude2",
        "OTEL_INJECTOR_INCLUDE_WITH_ARGUMENTS=--from-env-var-include1,--from-env-var-include2",
        "OTEL_INJECTOR_EXCLUDE_WITH_ARGUMENTS=--from-env-var-exclude1,--from-env-var-exclude2",
    });
    defer test_util.resetStdCEnviron(original_environ);

    var configuration = try readConfigurationFromPath(allocator, @constCast("/does/not/exist"));
    defer configuration.deinit(allocator);

    try testing.expectEqualStrings(
        "/path/from/env/var/dotnet",
        configuration.dotnet_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        "/path/from/env/var/jvm",
        configuration.jvm_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        "/path/from/env/var/nodejs",
        configuration.nodejs_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        default_all_auto_instrumentation_agents_env_path,
        configuration.all_auto_instrumentation_agents_env_path,
    );
    try testing.expectEqual(0, configuration.all_auto_instrumentation_agents_env_vars.count());
    try testing.expectEqual(2, configuration.include_paths.len);
    try testing.expectEqualStrings("/path/from/env/var/include1", configuration.include_paths[0]);
    try testing.expectEqualStrings("/path/from/env/var/include2", configuration.include_paths[1]);
    try testing.expectEqual(2, configuration.exclude_paths.len);
    try testing.expectEqualStrings("/path/from/env/var/exclude1", configuration.exclude_paths[0]);
    try testing.expectEqualStrings("/path/from/env/var/exclude2", configuration.exclude_paths[1]);
    try testing.expectEqual(2, configuration.include_args.len);
    try testing.expectEqualStrings("--from-env-var-include1", configuration.include_args[0]);
    try testing.expectEqualStrings("--from-env-var-include2", configuration.include_args[1]);
    try testing.expectEqual(2, configuration.exclude_args.len);
    try testing.expectEqualStrings("--from-env-var-exclude1", configuration.exclude_args[0]);
    try testing.expectEqualStrings("--from-env-var-exclude2", configuration.exclude_args[1]);
}

test "readConfigurationFromPath: all configuration values from file, no environment variables" {
    const allocator = testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_config_file =
        try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/config/all_values.conf" });
    defer allocator.free(absolute_path_to_config_file);

    const original_environ = try test_util.clearStdCEnviron();
    defer test_util.resetStdCEnviron(original_environ);

    var configuration = try readConfigurationFromPath(allocator, absolute_path_to_config_file);
    defer configuration.deinit(allocator);

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
    try testing.expectEqual(4, configuration.include_args.len);
    try testing.expectEqualStrings("-jar", configuration.include_args[0]);
    try testing.expectEqualStrings("*my-app*", configuration.include_args[1]);
    try testing.expectEqualStrings("*.js", configuration.include_args[2]);
    try testing.expectEqualStrings("*.dll", configuration.include_args[3]);
    try testing.expectEqual(3, configuration.exclude_args.len);
    try testing.expectEqualStrings("-javaagent*", configuration.exclude_args[0]);
    try testing.expectEqualStrings("*@opentelemetry-js*", configuration.exclude_args[1]);
    try testing.expectEqualStrings("-debug", configuration.exclude_args[2]);
}

test "readConfigurationFromPath: override some configuration values from file with environment variables" {
    const allocator = testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_config_file =
        try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/config/all_values.conf" });
    defer allocator.free(absolute_path_to_config_file);

    const original_environ = try test_util.setStdCEnviron(&[4][]const u8{
        "DOTNET_AUTO_INSTRUMENTATION_AGENT_PATH_PREFIX=/path/from/env/var/dotnet",
        "NODEJS_AUTO_INSTRUMENTATION_AGENT_PATH=/path/from/env/var/nodejs",
        "OTEL_INJECTOR_INCLUDE_PATHS=/path/from/env/var/include1,/path/from/env/var/include2",
        "OTEL_INJECTOR_EXCLUDE_WITH_ARGUMENTS=--from-env-var-exclude1,--from-env-var-exclude2",
    });
    defer test_util.resetStdCEnviron(original_environ);

    var configuration = try readConfigurationFromPath(allocator, absolute_path_to_config_file);
    defer configuration.deinit(allocator);

    try testing.expectEqualStrings(
        "/path/from/env/var/dotnet",
        configuration.dotnet_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        "/custom/path/to/jvm/javaagent.jar",
        configuration.jvm_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        "/path/from/env/var/nodejs",
        configuration.nodejs_auto_instrumentation_agent_path,
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
    try testing.expectEqual(4, configuration.include_args.len);
    try testing.expectEqualStrings("-jar", configuration.include_args[0]);
    try testing.expectEqualStrings("*my-app*", configuration.include_args[1]);
    try testing.expectEqualStrings("*.js", configuration.include_args[2]);
    try testing.expectEqualStrings("*.dll", configuration.include_args[3]);
    try testing.expectEqual(2, configuration.exclude_args.len);
    try testing.expectEqualStrings("--from-env-var-exclude1", configuration.exclude_args[0]);
    try testing.expectEqualStrings("--from-env-var-exclude2", configuration.exclude_args[1]);
}

fn createDefaultConfiguration(arena_allocator: std.mem.Allocator) std.mem.Allocator.Error!InjectorConfiguration {
    return InjectorConfiguration{
        .dotnet_auto_instrumentation_agent_path_prefix = try std.fmt.allocPrint(arena_allocator, "{s}", .{default_dotnet_auto_instrumentation_agent_path_prefix}),
        .jvm_auto_instrumentation_agent_path = try std.fmt.allocPrint(arena_allocator, "{s}", .{default_jvm_auto_instrumentation_agent_path}),
        .nodejs_auto_instrumentation_agent_path = try std.fmt.allocPrint(arena_allocator, "{s}", .{default_nodejs_auto_instrumentation_agent_path}),
        .all_auto_instrumentation_agents_env_path = try std.fmt.allocPrint(arena_allocator, "{s}", .{default_all_auto_instrumentation_agents_env_path}),
        .all_auto_instrumentation_agents_env_vars = std.StringHashMap([]u8).init(arena_allocator),
        .include_paths = &.{},
        .exclude_paths = &.{},
        .include_args = &.{},
        .exclude_args = &.{},
    };
}

fn applyCommaSeparatedPatternsOption(arena_allocator: std.mem.Allocator, setting: *[][]const u8, value: []u8, pattern_name: []const u8, cfg_file_path: []const u8) void {
    const new_patterns = patterns_util.splitByComma(arena_allocator, value) catch |err| {
        print.printError("error parsing {s} value from configuration file {s}: {}", .{ pattern_name, cfg_file_path, err });
        return;
    };
    setting.* = std.mem.concat(arena_allocator, []const u8, &.{ setting.*, new_patterns }) catch |err| {
        print.printError("error concatenating {s} from configuration file {s}: {}", .{ pattern_name, cfg_file_path, err });
        return;
    };
}

fn applyKeyValueToGeneralOptions(arena_allocator: std.mem.Allocator, key: []const u8, value: []u8, _cfg_file_path: []const u8, _configuration: *InjectorConfiguration) void {
    if (std.mem.eql(u8, key, dotnet_path_key)) {
        _configuration.dotnet_auto_instrumentation_agent_path_prefix = value;
    } else if (std.mem.eql(u8, key, jvm_path_key)) {
        _configuration.jvm_auto_instrumentation_agent_path = value;
    } else if (std.mem.eql(u8, key, nodejs_path_key)) {
        _configuration.nodejs_auto_instrumentation_agent_path = value;
    } else if (std.mem.eql(u8, key, all_agents_env_path_key)) {
        _configuration.all_auto_instrumentation_agents_env_path = value;
    } else if (std.mem.eql(u8, key, include_paths_key)) {
        applyCommaSeparatedPatternsOption(arena_allocator, &_configuration.include_paths, value, "include_paths", _cfg_file_path);
    } else if (std.mem.eql(u8, key, exclude_paths_key)) {
        applyCommaSeparatedPatternsOption(arena_allocator, &_configuration.exclude_paths, value, "exclude_paths", _cfg_file_path);
    } else if (std.mem.eql(u8, key, include_args_key)) {
        applyCommaSeparatedPatternsOption(arena_allocator, &_configuration.include_args, value, "include_arguments", _cfg_file_path);
    } else if (std.mem.eql(u8, key, exclude_args_key)) {
        applyCommaSeparatedPatternsOption(arena_allocator, &_configuration.exclude_args, value, "exclude_arguments", _cfg_file_path);
    } else {
        print.printError("ignoring unknown configuration key in {s}: {s}={s}", .{ _cfg_file_path, key, value });
    }
}

fn readConfigurationFile(arena_allocator: std.mem.Allocator, cfg_file_path: []const u8, configuration: *InjectorConfiguration) void {
    print.printDebug("reading configuration file from {s}.", .{cfg_file_path});
    const config_file = std.fs.cwd().openFile(cfg_file_path, .{}) catch |err| {
        print.printDebug(
            "The configuration file {s} does not exist or cannot be opened. Configuration will use default values and environment variables only. Error: {t}",
            .{ cfg_file_path, err },
        );
        return;
    };
    defer config_file.close();
    print.printDebug("successfully read configuration file from {s}.", .{cfg_file_path});

    return parseConfiguration(
        arena_allocator,
        configuration,
        config_file,
        cfg_file_path,
        applyKeyValueToGeneralOptions,
    );
}

fn applyKeyValueToAllAgentsEnv(_: std.mem.Allocator, key: []const u8, value: []u8, _file_path: []const u8, _configuration: *InjectorConfiguration) void {
    if (!std.mem.startsWith(u8, key, otel_env_var_prefix)) {
        print.printWarn("environment variable {s} does not start with {s}. ignoring.", .{ key, otel_env_var_prefix });
        return;
    }
    _configuration.all_auto_instrumentation_agents_env_vars.put(key, value) catch |e| {
        print.printError("error storing environment variable {s} from file {s}: {}", .{ key, _file_path, e });
    };
}

fn readAllAgentsEnvFile(arena_allocator: std.mem.Allocator, env_file_path: []const u8, configuration: *InjectorConfiguration) void {
    if (env_file_path.len == 0) {
        return;
    }

    const env_file = std.fs.cwd().openFile(env_file_path, .{}) catch |err| {
        print.printDebug("The configuration file {s} does not exist or cannot be opened. Error: {}", .{ env_file_path, err });
        return;
    };
    defer env_file.close();

    parseConfiguration(
        arena_allocator,
        configuration,
        env_file,
        env_file_path,
        applyKeyValueToAllAgentsEnv,
    );
}

fn parseConfiguration(
    arena_allocator: std.mem.Allocator,
    configuration: *InjectorConfiguration,
    config_file: std.fs.File,
    cfg_file_path: []const u8,
    comptime applyKeyValueToConfig: ConfigApplier,
) void {
    var buf: [max_line_length]u8 = undefined;
    var reader = config_file.reader(&buf);
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
    return InjectorConfiguration{
        .dotnet_auto_instrumentation_agent_path_prefix = try std.fmt.allocPrint(
            allocator,
            "{s}",
            .{preliminary_configuration.dotnet_auto_instrumentation_agent_path_prefix},
        ),
        .jvm_auto_instrumentation_agent_path = try std.fmt.allocPrint(
            allocator,
            "{s}",
            .{preliminary_configuration.jvm_auto_instrumentation_agent_path},
        ),
        .nodejs_auto_instrumentation_agent_path = try std.fmt.allocPrint(
            allocator,
            "{s}",
            .{preliminary_configuration.nodejs_auto_instrumentation_agent_path},
        ),
        .all_auto_instrumentation_agents_env_path = try std.fmt.allocPrint(
            allocator,
            "{s}",
            .{preliminary_configuration.all_auto_instrumentation_agents_env_path},
        ),
        .all_auto_instrumentation_agents_env_vars = try copyMap(
            allocator,
            preliminary_configuration.all_auto_instrumentation_agents_env_vars,
        ),
        .include_paths = try copyStringArray(allocator, preliminary_configuration.include_paths),
        .exclude_paths = try copyStringArray(allocator, preliminary_configuration.exclude_paths),
        .include_args = try copyStringArray(allocator, preliminary_configuration.include_args),
        .exclude_args = try copyStringArray(allocator, preliminary_configuration.exclude_args),
    };
}

fn takeSentinelOrDiscardOverlyLongLine(reader: *std.fs.File.Reader, cfg_file_path: []const u8) ![]u8 {
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
    readConfigurationFile(arena_allocator, "/does/not/exist", &configuration);

    try testing.expectEqualStrings(
        default_dotnet_auto_instrumentation_agent_path_prefix,
        configuration.dotnet_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        default_jvm_auto_instrumentation_agent_path,
        configuration.jvm_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        default_nodejs_auto_instrumentation_agent_path,
        configuration.nodejs_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        default_all_auto_instrumentation_agents_env_path,
        configuration.all_auto_instrumentation_agents_env_path,
    );
    try testing.expectEqual(0, configuration.all_auto_instrumentation_agents_env_vars.count());
    try testing.expectEqual(0, configuration.include_paths.len);
    try testing.expectEqual(0, configuration.exclude_paths.len);
    try testing.expectEqual(0, configuration.include_args.len);
    try testing.expectEqual(0, configuration.exclude_args.len);
}

test "readConfigurationFile: empty file" {
    const allocator = testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_config_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/config/empty.conf" });
    defer allocator.free(absolute_path_to_config_file);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var configuration = try createDefaultConfiguration(arena_allocator);
    readConfigurationFile(arena_allocator, absolute_path_to_config_file, &configuration);

    try testing.expectEqualStrings(
        default_dotnet_auto_instrumentation_agent_path_prefix,
        configuration.dotnet_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        default_jvm_auto_instrumentation_agent_path,
        configuration.jvm_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        default_nodejs_auto_instrumentation_agent_path,
        configuration.nodejs_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        default_all_auto_instrumentation_agents_env_path,
        configuration.all_auto_instrumentation_agents_env_path,
    );
    try testing.expectEqual(0, configuration.all_auto_instrumentation_agents_env_vars.count());
    try testing.expectEqual(0, configuration.include_paths.len);
    try testing.expectEqual(0, configuration.exclude_paths.len);
    try testing.expectEqual(0, configuration.include_args.len);
    try testing.expectEqual(0, configuration.exclude_args.len);
}

test "readConfigurationFile: all configuration values" {
    const allocator = testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_config_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/config/all_values.conf" });
    defer allocator.free(absolute_path_to_config_file);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var configuration = try createDefaultConfiguration(arena_allocator);
    readConfigurationFile(arena_allocator, absolute_path_to_config_file, &configuration);

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
    try testing.expectEqual(4, configuration.include_args.len);
    try testing.expectEqualStrings("-jar", configuration.include_args[0]);
    try testing.expectEqualStrings("*my-app*", configuration.include_args[1]);
    try testing.expectEqualStrings("*.js", configuration.include_args[2]);
    try testing.expectEqualStrings("*.dll", configuration.include_args[3]);
    try testing.expectEqual(3, configuration.exclude_args.len);
    try testing.expectEqualStrings("-javaagent*", configuration.exclude_args[0]);
    try testing.expectEqualStrings("*@opentelemetry-js*", configuration.exclude_args[1]);
    try testing.expectEqualStrings("-debug", configuration.exclude_args[2]);
}

test "readConfigurationFile: all configuration values plus whitespace and comments" {
    const allocator = testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_config_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/config/with_comments_and_whitespace.conf" });
    defer allocator.free(absolute_path_to_config_file);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var configuration = try createDefaultConfiguration(arena_allocator);
    readConfigurationFile(arena_allocator, absolute_path_to_config_file, &configuration);

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
        "/custom/path/to/auto_instrumentation_env.conf",
        configuration.all_auto_instrumentation_agents_env_path,
    );
}

test "readConfigurationFile: does not parse overly long lines" {
    const allocator = testing.allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_config_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/config/very_long_lines.conf" });
    defer allocator.free(absolute_path_to_config_file);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var configuration = try createDefaultConfiguration(arena_allocator);
    readConfigurationFile(arena_allocator, absolute_path_to_config_file, &configuration);

    try testing.expectEqualStrings(
        default_dotnet_auto_instrumentation_agent_path_prefix,
        configuration.dotnet_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        "/this/line/should/be/parsed",
        configuration.jvm_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        default_nodejs_auto_instrumentation_agent_path,
        configuration.nodejs_auto_instrumentation_agent_path,
    );
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
        const value = std.fmt.allocPrint(arena_allocator, "{s}", .{value_trimmed}) catch |err| {
            print.printError("error in allocPrint while allocating value from file {s}: {}", .{ cfg_file_path, err });
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

fn readConfigurationFromEnvironment(arena_allocator: std.mem.Allocator, configuration: *InjectorConfiguration) void {
    if (std.posix.getenv(dotnet_path_env_var)) |value| {
        const trimmed_value = std.mem.trim(u8, value, " \t\r\n");
        const dotnet_value = std.fmt.allocPrint(arena_allocator, "{s}", .{trimmed_value}) catch |err| {
            print.printError("Cannot allocate memory to read the injector configuration from the environment: {}", .{err});
            return;
        };
        configuration.dotnet_auto_instrumentation_agent_path_prefix = dotnet_value;
    }
    if (std.posix.getenv(jvm_path_env_var)) |value| {
        const trimmed_value = std.mem.trim(u8, value, " \t\r\n");
        const jvm_value = std.fmt.allocPrint(arena_allocator, "{s}", .{trimmed_value}) catch |err| {
            print.printError("Cannot allocate memory to read the injector configuration from the environment: {}", .{err});
            return;
        };
        configuration.jvm_auto_instrumentation_agent_path = jvm_value;
    }
    if (std.posix.getenv(nodejs_path_env_var)) |value| {
        const trimmed_value = std.mem.trim(u8, value, " \t\r\n");
        const nodejs_value = std.fmt.allocPrint(arena_allocator, "{s}", .{trimmed_value}) catch |err| {
            print.printError("Cannot allocate memory to read the injector configuration from the environment: {}", .{err});
            return;
        };
        configuration.nodejs_auto_instrumentation_agent_path = nodejs_value;
    }
    if (std.posix.getenv(include_paths_env_var)) |value| {
        const trimmed_value = std.mem.trim(u8, value, " \t\r\n");
        const include_paths_value = std.fmt.allocPrint(arena_allocator, "{s}", .{trimmed_value}) catch |err| {
            print.printError("Cannot allocate memory to read the injector configuration from the environment: {}", .{err});
            return;
        };
        configuration.include_paths = patterns_util.splitByComma(arena_allocator, include_paths_value) catch |err| {
            print.printError("error parsing include_paths value from the environment {s}: {}", .{ include_paths_value, err });
            return;
        };
    }
    if (std.posix.getenv(exclude_paths_env_var)) |value| {
        const trimmed_value = std.mem.trim(u8, value, " \t\r\n");
        const exclude_paths_value = std.fmt.allocPrint(arena_allocator, "{s}", .{trimmed_value}) catch |err| {
            print.printError("Cannot allocate memory to read the injector configuration from the environment: {}", .{err});
            return;
        };
        configuration.exclude_paths = patterns_util.splitByComma(arena_allocator, exclude_paths_value) catch |err| {
            print.printError("error parsing exclude_paths value from the environment {s}: {}", .{ exclude_paths_value, err });
            return;
        };
    }
    if (std.posix.getenv(include_args_env_var)) |value| {
        const trimmed_value = std.mem.trim(u8, value, " \t\r\n");
        const include_args_value = std.fmt.allocPrint(arena_allocator, "{s}", .{trimmed_value}) catch |err| {
            print.printError("Cannot allocate memory to read the injector configuration from the environment: {}", .{err});
            return;
        };
        configuration.include_args = patterns_util.splitByComma(arena_allocator, include_args_value) catch |err| {
            print.printError("error parsing include_arguments value from the environment {s}: {}", .{ include_args_value, err });
            return;
        };
    }
    if (std.posix.getenv(exclude_args_env_var)) |value| {
        const trimmed_value = std.mem.trim(u8, value, " \t\r\n");
        const exclude_args_value = std.fmt.allocPrint(arena_allocator, "{s}", .{trimmed_value}) catch |err| {
            print.printError("Cannot allocate memory to read the injector configuration from the environment: {}", .{err});
            return;
        };
        configuration.exclude_args = patterns_util.splitByComma(arena_allocator, exclude_args_value) catch |err| {
            print.printError("error parsing exclude_arguments value from the environment {s}: {}", .{ exclude_args_value, err });
            return;
        };
    }
}

test "readConfigurationFromEnvironment: empty environment values" {
    const allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const original_environ = try test_util.clearStdCEnviron();
    defer test_util.resetStdCEnviron(original_environ);

    var configuration = try createDefaultConfiguration(arena_allocator);
    readConfigurationFromEnvironment(arena_allocator, &configuration);

    try testing.expectEqualStrings(
        default_dotnet_auto_instrumentation_agent_path_prefix,
        configuration.dotnet_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        default_jvm_auto_instrumentation_agent_path,
        configuration.jvm_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        default_nodejs_auto_instrumentation_agent_path,
        configuration.nodejs_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        default_all_auto_instrumentation_agents_env_path,
        configuration.all_auto_instrumentation_agents_env_path,
    );
    try testing.expectEqual(0, configuration.include_paths.len);
    try testing.expectEqual(0, configuration.exclude_paths.len);
    try testing.expectEqual(0, configuration.include_args.len);
    try testing.expectEqual(0, configuration.exclude_args.len);
}

test "readConfigurationFromEnvironment: all values" {
    const allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const original_environ = try test_util.setStdCEnviron(&[7][]const u8{
        "DOTNET_AUTO_INSTRUMENTATION_AGENT_PATH_PREFIX=/path/from/env/var/dotnet",
        "JVM_AUTO_INSTRUMENTATION_AGENT_PATH=/path/from/env/var/jvm",
        "NODEJS_AUTO_INSTRUMENTATION_AGENT_PATH=/path/from/env/var/nodejs",
        "OTEL_INJECTOR_INCLUDE_PATHS=/path/from/env/var/include1,/path/from/env/var/include2",
        "OTEL_INJECTOR_EXCLUDE_PATHS=/path/from/env/var/exclude1,/path/from/env/var/exclude2",
        "OTEL_INJECTOR_INCLUDE_WITH_ARGUMENTS=--from-env-var-include1,--from-env-var-include2",
        "OTEL_INJECTOR_EXCLUDE_WITH_ARGUMENTS=--from-env-var-exclude1,--from-env-var-exclude2",
    });
    defer test_util.resetStdCEnviron(original_environ);

    var configuration = try createDefaultConfiguration(arena_allocator);
    readConfigurationFromEnvironment(arena_allocator, &configuration);

    try testing.expectEqualStrings(
        "/path/from/env/var/dotnet",
        configuration.dotnet_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        "/path/from/env/var/jvm",
        configuration.jvm_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        "/path/from/env/var/nodejs",
        configuration.nodejs_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        default_all_auto_instrumentation_agents_env_path,
        configuration.all_auto_instrumentation_agents_env_path,
    );
    try testing.expectEqual(2, configuration.include_paths.len);
    try testing.expectEqualStrings("/path/from/env/var/include1", configuration.include_paths[0]);
    try testing.expectEqualStrings("/path/from/env/var/include2", configuration.include_paths[1]);
    try testing.expectEqual(2, configuration.exclude_paths.len);
    try testing.expectEqualStrings("/path/from/env/var/exclude1", configuration.exclude_paths[0]);
    try testing.expectEqualStrings("/path/from/env/var/exclude2", configuration.exclude_paths[1]);
    try testing.expectEqual(2, configuration.include_args.len);
    try testing.expectEqualStrings("--from-env-var-include1", configuration.include_args[0]);
    try testing.expectEqualStrings("--from-env-var-include2", configuration.include_args[1]);
    try testing.expectEqual(2, configuration.exclude_args.len);
    try testing.expectEqualStrings("--from-env-var-exclude1", configuration.exclude_args[0]);
    try testing.expectEqualStrings("--from-env-var-exclude2", configuration.exclude_args[1]);
}

fn copyMap(allocator: std.mem.Allocator, source: std.StringHashMap([]u8)) !std.StringHashMap([]u8) {
    var target = std.StringHashMap([]u8).init(allocator);
    try target.ensureTotalCapacity(source.count());
    var it = source.iterator();
    while (it.next()) |entry| {
        const key = try std.fmt.allocPrint(allocator, "{s}", .{entry.key_ptr.*});
        const value = try std.fmt.allocPrint(allocator, "{s}", .{entry.value_ptr.*});
        try target.put(key, value);
    }
    return target;
}

fn copyStringArray(allocator: std.mem.Allocator, source: [][]const u8) std.mem.Allocator.Error![][]const u8 {
    const target = try allocator.alloc([]const u8, source.len);
    for (source, 0..) |p, i| {
        target[i] = try std.fmt.allocPrint(allocator, "{s}", .{p});
    }
    return target;
}

fn deinitStringArray(allocator: std.mem.Allocator, array: [][]const u8) void {
    for (array) |item| {
        allocator.free(item);
    }
    allocator.free(array);
}
