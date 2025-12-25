// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const print = @import("print.zig");
const test_util = @import("test_util.zig");
const patterns_util = @import("patterns_util.zig");

const testing = std.testing;

const config_file_path = "/etc/opentelemetry/otelinject.conf";
const max_line_length = 8192;
const empty_string = @constCast("");

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
    all_auto_instrumentation_agents_env_path: []u8,
    all_auto_instrumentation_agents_env_vars: std.StringHashMap([]u8),
    dotnet_auto_instrumentation_agent_path_prefix: []u8,
    jvm_auto_instrumentation_agent_path: []u8,
    nodejs_auto_instrumentation_agent_path: []u8,
    include_paths: [][]const u8,
    exclude_paths: [][]const u8,
    include_args: [][]const u8,
    exclude_args: [][]const u8,

    pub fn freeAll(self: *InjectorConfiguration, allocator: std.mem.Allocator) void {
        allocator.free(self.all_auto_instrumentation_agents_env_path);
        self.all_auto_instrumentation_agents_env_vars.deinit();
        allocator.free(self.dotnet_auto_instrumentation_agent_path_prefix);
        allocator.free(self.jvm_auto_instrumentation_agent_path);
        allocator.free(self.nodejs_auto_instrumentation_agent_path);
    }
};

const ConfigApplier = fn (gpa: std.mem.Allocator, key: []const u8, value: []u8, file_path: []const u8, configuration: *InjectorConfiguration) void;

const default_dotnet_auto_instrumentation_agent_path_prefix = "/__otel_auto_instrumentation/dotnet";
const default_jvm_auto_instrumentation_agent_path = "/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar";
const default_nodejs_auto_instrumentation_agent_path = "/__otel_auto_instrumentation/node_js/node_modules/@opentelemetry-js/otel/instrument";

const default_all_auto_instrumentation_agents_env_path = "/etc/opentelemetry/default_auto_instrumentation_env.conf";

var cached_configuration_optional: ?InjectorConfiguration = null;

/// Checks whether the configuration has already been read and reads it if necessary. The configuration will only be
/// read once per process and the result will be cached for subsequent calls.
///
/// The configuration will be read from the file /etc/opentelemetry/otelinject.conf (if it exists) and from environment
/// variables. Environment variables have higher precedence and can override settings from the configuration file.
pub fn readConfiguration(gpa: std.mem.Allocator) InjectorConfiguration {
    if (cached_configuration_optional) |cached_configuration| {
        return cached_configuration;
    }

    var configuration = createDefaultConfiguration(gpa);
    readConfigurationFile(gpa, config_file_path, &configuration);
    readConfigurationFromEnvironment(gpa, &configuration);
    readAllAgentsEnvFile(gpa, configuration.all_auto_instrumentation_agents_env_path, &configuration);
    cached_configuration_optional = configuration;
    return configuration;
}

fn printErrorReturnEmptyConfig(gpa: std.mem.Allocator, err: std.mem.Allocator.Error) InjectorConfiguration {
    print.printError("Cannot allocate memory for the default injector configuration: {t}", .{err});
    return InjectorConfiguration{
        .dotnet_auto_instrumentation_agent_path_prefix = "",
        .jvm_auto_instrumentation_agent_path = "",
        .nodejs_auto_instrumentation_agent_path = "",
        .all_auto_instrumentation_agents_env_path = "",
        .all_auto_instrumentation_agents_env_vars = std.StringHashMap([]u8).init(gpa),
        .include_paths = &.{},
        .exclude_paths = &.{},
        .include_args = &.{},
        .exclude_args = &.{},
    };
}

fn createDefaultConfiguration(gpa: std.mem.Allocator) InjectorConfiguration {
    const all_agent_env_vars = std.StringHashMap([]u8).init(gpa);

    const all_env_default = std.fmt.allocPrint(gpa, "{s}", .{default_all_auto_instrumentation_agents_env_path}) catch |err| {
        return printErrorReturnEmptyConfig(gpa, err);
    };
    const dotnet_default = std.fmt.allocPrint(gpa, "{s}", .{default_dotnet_auto_instrumentation_agent_path_prefix}) catch |err| {
        return printErrorReturnEmptyConfig(gpa, err);
    };
    const jvm_default = std.fmt.allocPrint(gpa, "{s}", .{default_jvm_auto_instrumentation_agent_path}) catch |err| {
        return printErrorReturnEmptyConfig(gpa, err);
    };
    const nodejs_default = std.fmt.allocPrint(gpa, "{s}", .{default_nodejs_auto_instrumentation_agent_path}) catch |err| {
        return printErrorReturnEmptyConfig(gpa, err);
    };

    return InjectorConfiguration{
        .dotnet_auto_instrumentation_agent_path_prefix = dotnet_default,
        .jvm_auto_instrumentation_agent_path = jvm_default,
        .nodejs_auto_instrumentation_agent_path = nodejs_default,
        .all_auto_instrumentation_agents_env_path = all_env_default,
        .all_auto_instrumentation_agents_env_vars = all_agent_env_vars,
        .include_paths = &.{},
        .exclude_paths = &.{},
        .include_args = &.{},
        .exclude_args = &.{},
    };
}

fn applyCommaSeparatedPatternsOption(gpa: std.mem.Allocator, setting: *[][]const u8, value: []u8, pattern_name: []const u8, cfg_file_path: []const u8) void {
    const new_patterns = patterns_util.splitByComma(gpa, value) catch |err| {
        print.printError("error parsing {s} value from configuration file {s}: {}", .{ pattern_name, cfg_file_path, err });
        return;
    };
    setting.* = std.mem.concat(gpa, []const u8, &.{ setting.*, new_patterns }) catch |err| {
        print.printError("error concatenating {s} from configuration file {s}: {}", .{ pattern_name, cfg_file_path, err });
        return;
    };
}

fn applyKeyValueToGeneralOptions(gpa: std.mem.Allocator, key: []const u8, value: []u8, _cfg_file_path: []const u8, _configuration: *InjectorConfiguration) void {
    if (std.mem.eql(u8, key, all_agents_env_path_key)) {
        _configuration.all_auto_instrumentation_agents_env_path = value;
    } else if (std.mem.eql(u8, key, dotnet_path_key)) {
        _configuration.dotnet_auto_instrumentation_agent_path_prefix = value;
    } else if (std.mem.eql(u8, key, jvm_path_key)) {
        _configuration.jvm_auto_instrumentation_agent_path = value;
    } else if (std.mem.eql(u8, key, nodejs_path_key)) {
        _configuration.nodejs_auto_instrumentation_agent_path = value;
    } else if (std.mem.eql(u8, key, include_paths_key)) {
        applyCommaSeparatedPatternsOption(gpa, &_configuration.include_paths, value, "include_paths", _cfg_file_path);
    } else if (std.mem.eql(u8, key, exclude_paths_key)) {
        applyCommaSeparatedPatternsOption(gpa, &_configuration.exclude_paths, value, "exclude_paths", _cfg_file_path);
    } else if (std.mem.eql(u8, key, include_args_key)) {
        applyCommaSeparatedPatternsOption(gpa, &_configuration.include_args, value, "include_arguments", _cfg_file_path);
    } else if (std.mem.eql(u8, key, exclude_args_key)) {
        applyCommaSeparatedPatternsOption(gpa, &_configuration.exclude_args, value, "exclude_arguments", _cfg_file_path);
    } else {
        print.printError("ignoring unknown configuration key in {s}: {s}={s}", .{ _cfg_file_path, key, value });
        gpa.free(value);
    }
}

fn readConfigurationFile(gpa: std.mem.Allocator, cfg_file_path: []const u8, configuration: *InjectorConfiguration) void {
    const config_file = std.fs.cwd().openFile(cfg_file_path, .{}) catch |err| {
        print.printDebug(
            "The configuration file {s} does not exist or cannot be opened. Configuration will use default values and environment variables only. Error: {t}",
            .{ cfg_file_path, err },
        );
        return;
    };
    defer config_file.close();

    return parseConfiguration(
        gpa,
        configuration,
        config_file,
        cfg_file_path,
        applyKeyValueToGeneralOptions,
    );
}

fn applyKeyValueToAllAgentsEnv(_: std.mem.Allocator, key: []const u8, value: []u8, _file_path: []const u8, _configuration: *InjectorConfiguration) void {
    _configuration.all_auto_instrumentation_agents_env_vars.put(key, value) catch |e| {
        print.printError("error storing environment variable {s} from file {s}: {}", .{ key, _file_path, e });
    };
}

fn readAllAgentsEnvFile(gpa: std.mem.Allocator, env_file_path: []const u8, configuration: *InjectorConfiguration) void {
    if (env_file_path.len == 0) {
        return;
    }

    const env_file = std.fs.cwd().openFile(env_file_path, .{}) catch |err| {
        print.printDebug("The configuration file {s} does not exist or cannot be opened. Error: {}", .{ env_file_path, err });
        return;
    };
    defer env_file.close();

    return parseConfiguration(gpa, configuration, env_file, env_file_path, applyKeyValueToAllAgentsEnv);
}

fn parseConfiguration(
    gpa: std.mem.Allocator,
    configuration: *InjectorConfiguration,
    config_file: std.fs.File,
    cfg_file_path: []const u8,
    comptime applyKeyValueToConfig: ConfigApplier,
) void {
    var buf: [max_line_length]u8 = undefined;
    var reader = config_file.reader(&buf);
    while (takeSentinelOrDiscardOverlyLongLine(&reader, cfg_file_path)) |line| {
        if (parseLine(gpa, line, cfg_file_path)) |kv| {
            applyKeyValueToConfig(gpa, kv.key, kv.value, cfg_file_path, configuration);
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
            if (parseLine(gpa, buffer[0..chars], cfg_file_path)) |kv| {
                applyKeyValueToConfig(gpa, kv.key, kv.value, cfg_file_path, configuration);
            }
        },
    }
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
    const allocator = std.heap.page_allocator;
    var configuration = createDefaultConfiguration(allocator);
    defer configuration.freeAll(allocator);

    readConfigurationFile(allocator, "/does/not/exist", &configuration);

    try testing.expectEqualStrings(
        default_all_auto_instrumentation_agents_env_path,
        configuration.all_auto_instrumentation_agents_env_path,
    );
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
    try testing.expectEqual(0, configuration.include_paths.len);
    try testing.expectEqual(0, configuration.exclude_paths.len);
    try testing.expectEqual(0, configuration.include_args.len);
    try testing.expectEqual(0, configuration.exclude_args.len);
}

test "readConfigurationFile: empty file" {
    const allocator = std.heap.page_allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_config_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/config/empty.conf" });
    defer allocator.free(absolute_path_to_config_file);

    var configuration = createDefaultConfiguration(allocator);
    defer configuration.freeAll(allocator);

    readConfigurationFile(allocator, absolute_path_to_config_file, &configuration);

    try testing.expectEqualStrings(
        default_all_auto_instrumentation_agents_env_path,
        configuration.all_auto_instrumentation_agents_env_path,
    );
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
    try testing.expectEqual(0, configuration.include_paths.len);
    try testing.expectEqual(0, configuration.exclude_paths.len);
    try testing.expectEqual(0, configuration.include_args.len);
    try testing.expectEqual(0, configuration.exclude_args.len);
}

test "readConfigurationFile: all configuration values" {
    const allocator = std.heap.page_allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_config_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/config/all_values.conf" });
    defer allocator.free(absolute_path_to_config_file);
    var configuration = createDefaultConfiguration(allocator);

    readConfigurationFile(allocator, absolute_path_to_config_file, &configuration);

    try testing.expectEqualStrings(
        "/custom/path/to/auto_instrumentation_env.conf",
        configuration.all_auto_instrumentation_agents_env_path,
    );
    try testing.expectEqualStrings(
        "/custom/path/to/dotnet/instrumentation",
        configuration.dotnet_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        "/custom/path/to/jvm/opentelemetry-javaagent.jar",
        configuration.jvm_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        "/custom/path/to/node_js/node_modules/@opentelemetry-js/otel/instrument",
        configuration.nodejs_auto_instrumentation_agent_path,
    );
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
    const allocator = std.heap.page_allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_config_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/config/with_comments_and_whitespace.conf" });
    defer allocator.free(absolute_path_to_config_file);
    var configuration = createDefaultConfiguration(allocator);
    defer configuration.freeAll(allocator);

    readConfigurationFile(allocator, absolute_path_to_config_file, &configuration);

    try testing.expectEqualStrings(
        "/custom/path/to/auto_instrumentation_env.conf",
        configuration.all_auto_instrumentation_agents_env_path,
    );
    try testing.expectEqualStrings(
        "/custom/path/to/dotnet/instrumentation",
        configuration.dotnet_auto_instrumentation_agent_path_prefix,
    );
    try testing.expectEqualStrings(
        "/custom/path/to/jvm/opentelemetry-javaagent.jar",
        configuration.jvm_auto_instrumentation_agent_path,
    );
    try testing.expectEqualStrings(
        "/custom/path/to/node_js/node_modules/@opentelemetry-js/otel/instrument",
        configuration.nodejs_auto_instrumentation_agent_path,
    );
}

test "readConfigurationFile: does not parse overly long lines" {
    const allocator = std.heap.page_allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_config_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/config/very_long_lines.conf" });
    defer allocator.free(absolute_path_to_config_file);
    var configuration = createDefaultConfiguration(allocator);
    defer configuration.freeAll(allocator);

    readConfigurationFile(allocator, absolute_path_to_config_file, &configuration);

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
fn parseLine(gpa: std.mem.Allocator, line: []u8, cfg_file_path: []const u8) ?struct {
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
        const key = std.fmt.allocPrint(gpa, "{s}", .{key_trimmed}) catch |err| {
            print.printError("error in allocPrint while allocating key from file {s}: {}", .{ cfg_file_path, err });
            return null;
        };
        const value_trimmed = std.mem.trim(u8, trimmed[equalsIdx + 1 ..], " \t\r\n");
        const value = std.fmt.allocPrint(gpa, "{s}", .{value_trimmed}) catch |err| {
            print.printError("error in allocPrint while allocating value from file {s}: {}", .{ cfg_file_path, err });
            gpa.free(key);
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

fn readConfigurationFromEnvironment(gpa: std.mem.Allocator, configuration: *InjectorConfiguration) void {
    if (std.posix.getenv(dotnet_path_env_var)) |value| {
        const trimmed_value = std.mem.trim(u8, value, " \t\r\n");
        const dotnet_value = std.fmt.allocPrint(gpa, "{s}", .{trimmed_value}) catch |err| {
            print.printError("Cannot allocate memory to read the injector configuration from the environment: {}", .{err});
            return;
        };
        configuration.dotnet_auto_instrumentation_agent_path_prefix = dotnet_value;
    }
    if (std.posix.getenv(jvm_path_env_var)) |value| {
        const trimmed_value = std.mem.trim(u8, value, " \t\r\n");
        const jvm_value = std.fmt.allocPrint(gpa, "{s}", .{trimmed_value}) catch |err| {
            print.printError("Cannot allocate memory to read the injector configuration from the environment: {}", .{err});
            return;
        };
        configuration.jvm_auto_instrumentation_agent_path = jvm_value;
    }
    if (std.posix.getenv(nodejs_path_env_var)) |value| {
        const trimmed_value = std.mem.trim(u8, value, " \t\r\n");
        const nodejs_value = std.fmt.allocPrint(gpa, "{s}", .{trimmed_value}) catch |err| {
            print.printError("Cannot allocate memory to read the injector configuration from the environment: {}", .{err});
            return;
        };
        configuration.nodejs_auto_instrumentation_agent_path = nodejs_value;
    }
    if (std.posix.getenv(include_paths_env_var)) |value| {
        const trimmed_value = std.mem.trim(u8, value, " \t\r\n");
        const include_paths_value = std.fmt.allocPrint(gpa, "{s}", .{trimmed_value}) catch |err| {
            print.printError("Cannot allocate memory to read the injector configuration from the environment: {}", .{err});
            return;
        };
        configuration.include_paths = patterns_util.splitByComma(gpa, include_paths_value) catch |err| {
            print.printError("error parsing include_paths value from the environment {s}: {}", .{ include_paths_value, err });
            return;
        };
    }
    if (std.posix.getenv(exclude_paths_env_var)) |value| {
        const trimmed_value = std.mem.trim(u8, value, " \t\r\n");
        const exclude_paths_value = std.fmt.allocPrint(gpa, "{s}", .{trimmed_value}) catch |err| {
            print.printError("Cannot allocate memory to read the injector configuration from the environment: {}", .{err});
            return;
        };
        configuration.exclude_paths = patterns_util.splitByComma(gpa, exclude_paths_value) catch |err| {
            print.printError("error parsing exclude_paths value from the environment {s}: {}", .{ exclude_paths_value, err });
            return;
        };
    }
    if (std.posix.getenv(include_args_env_var)) |value| {
        const trimmed_value = std.mem.trim(u8, value, " \t\r\n");
        const include_args_value = std.fmt.allocPrint(gpa, "{s}", .{trimmed_value}) catch |err| {
            print.printError("Cannot allocate memory to read the injector configuration from the environment: {}", .{err});
            return;
        };
        configuration.include_args = patterns_util.splitByComma(gpa, include_args_value) catch |err| {
            print.printError("error parsing include_arguments value from the environment {s}: {}", .{ include_args_value, err });
            return;
        };
    }
    if (std.posix.getenv(exclude_args_env_var)) |value| {
        const trimmed_value = std.mem.trim(u8, value, " \t\r\n");
        const exclude_args_value = std.fmt.allocPrint(gpa, "{s}", .{trimmed_value}) catch |err| {
            print.printError("Cannot allocate memory to read the injector configuration from the environment: {}", .{err});
            return;
        };
        configuration.exclude_args = patterns_util.splitByComma(gpa, exclude_args_value) catch |err| {
            print.printError("error parsing exclude_arguments value from the environment {s}: {}", .{ exclude_args_value, err });
            return;
        };
    }
}
