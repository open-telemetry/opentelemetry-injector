// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const alloc = @import("allocator.zig");
const print = @import("print.zig");
const test_util = @import("test_util.zig");

const testing = std.testing;

const config_file_path = "/etc/opentelemetry/otelinject.conf";
const max_line_length = 8192;

const dotnet_path_key = "dotnet_auto_instrumentation_agent_path_prefix";
const jvm_path_key = "jvm_auto_instrumentation_agent_path";
const nodejs_path_key = "nodejs_auto_instrumentation_agent_path";

const dotnet_path_env_var = "DOTNET_AUTO_INSTRUMENTATION_AGENT_PATH_PREFIX";
const jvm_path_env_var = "JVM_AUTO_INSTRUMENTATION_AGENT_PATH";
const nodejs_path_env_var = "NODEJS_AUTO_INSTRUMENTATION_AGENT_PATH";

pub const InjectorConfiguration = struct {
    dotnet_auto_instrumentation_agent_path_prefix: []u8,
    jvm_auto_instrumentation_agent_path: []u8,
    nodejs_auto_instrumentation_agent_path: []u8,
};

const default_dotnet_auto_instrumentation_agent_path_prefix = "/__otel_auto_instrumentation/dotnet";
const default_jvm_auto_instrumentation_agent_path = "/__otel_auto_instrumentation/jvm/opentelemetry-javaagent.jar";
const default_nodejs_auto_instrumentation_agent_path = "/__otel_auto_instrumentation/node_js/node_modules/@opentelemetry-js/otel/instrument";

var cached_configuration_optional: ?InjectorConfiguration = null;

/// Checks whether the configuration has already been read and reads it if necessary. The configuration will only be
/// read once per process and the result will be cached for subsequent calls.
///
/// The configuration will be read from the file /etc/opentelemetry/otelinject.conf (if it exists) and from environment
/// variables. Environment variables have higher precedence and can override settings from the configuration file.
pub fn readConfiguration() InjectorConfiguration {
    if (cached_configuration_optional) |cached_configuration| {
        return cached_configuration;
    }

    var configuration = createDefaultConfiguration();
    readConfigurationFile(config_file_path, &configuration);
    readConfigurationFromEnvironment(&configuration);
    cached_configuration_optional = configuration;
    return configuration;
}

fn createDefaultConfiguration() InjectorConfiguration {
    const dotnet_default =
        std.fmt.allocPrint(alloc.page_allocator, "{s}", .{default_dotnet_auto_instrumentation_agent_path_prefix}) catch |err| {
            print.printError("Cannot allocate memory for the default injector configuration: {}", .{err});
            return InjectorConfiguration{
                .dotnet_auto_instrumentation_agent_path_prefix = "",
                .jvm_auto_instrumentation_agent_path = "",
                .nodejs_auto_instrumentation_agent_path = "",
            };
        };
    const jvm_default =
        std.fmt.allocPrint(alloc.page_allocator, "{s}", .{default_jvm_auto_instrumentation_agent_path}) catch |err| {
            print.printError("Cannot allocate memory for the default injector configuration: {}", .{err});
            return InjectorConfiguration{
                .dotnet_auto_instrumentation_agent_path_prefix = "",
                .jvm_auto_instrumentation_agent_path = "",
                .nodejs_auto_instrumentation_agent_path = "",
            };
        };
    const nodejs_default =
        std.fmt.allocPrint(alloc.page_allocator, "{s}", .{default_nodejs_auto_instrumentation_agent_path}) catch |err| {
            print.printError("Cannot allocate memory for the default injector configuration: {}", .{err});
            return InjectorConfiguration{
                .dotnet_auto_instrumentation_agent_path_prefix = "",
                .jvm_auto_instrumentation_agent_path = "",
                .nodejs_auto_instrumentation_agent_path = "",
            };
        };

    return InjectorConfiguration{
        .dotnet_auto_instrumentation_agent_path_prefix = dotnet_default,
        .jvm_auto_instrumentation_agent_path = jvm_default,
        .nodejs_auto_instrumentation_agent_path = nodejs_default,
    };
}

fn readConfigurationFile(cfg_file_path: []const u8, configuration: *InjectorConfiguration) void {
    const config_file = std.fs.cwd().openFile(cfg_file_path, .{}) catch |err| {
        print.printDebug("The configuration file {s} does not exist or cannot be opened. Configuration will use default values and environment variables only. Error: {}", .{ cfg_file_path, err });
        return;
    };
    defer config_file.close();
    var line_buffer_array = std.ArrayList(u8).init(alloc.page_allocator);
    defer line_buffer_array.deinit();

    while (true) {
        config_file.reader().streamUntilDelimiter(
            line_buffer_array.writer(),
            '\n',
            max_line_length,
        ) catch |err| switch (err) {
            error.EndOfStream => {
                // streamUntilDelimiter writes you the very last line (which is not terminated by \n) to
                // line_buffer_array while simultaneously returning error.EndOfStream. That means we still need to call
                // parseLine call here once, otherwise we would accidentally ignore the very last line of the file.
                const line = line_buffer_array.toOwnedSlice() catch |e| {
                    print.printError("error in toOwnedSlice while reading configuration file {s}: {}", .{ cfg_file_path, e });
                    break;
                };
                defer alloc.page_allocator.free(line);
                _ = parseLine(line, cfg_file_path, configuration);
                break;
            },
            error.StreamTooLong => {
                print.printError("ignoring overly long line in configuration file {s} with more than {d} characters", .{ cfg_file_path, max_line_length });
                line_buffer_array.clearAndFree();

                // If this happens, we have not consumed the overly long line completely until the end-of-line
                // delimeter, because streamUntilDelimiter stops when max_line_length have been read. We need to make
                // sure the rest of the line (until the next \n) is discarded as well.
                config_file.reader().skipUntilDelimiterOrEof('\n') catch |e| {
                    print.printError(
                        "read error when skipping until the end of an overly long line while reading configuration file {s}: {}",
                        .{ cfg_file_path, e },
                    );
                    break;
                };
                continue;
            },
            else => |e| {
                print.printError("read error while reading configuration file {s}: {}", .{ cfg_file_path, e });
                break;
            },
        };
        const line = line_buffer_array.toOwnedSlice() catch |e| {
            print.printError("error in toOwnedSlice while reading configuration file {s}: {}", .{ cfg_file_path, e });
            break;
        };
        defer alloc.page_allocator.free(line);
        _ = parseLine(line, cfg_file_path, configuration);
    }
}

test "readConfigurationFile: file does not exist" {
    var configuration = createDefaultConfiguration();

    readConfigurationFile("/does/not/exist", &configuration);

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
}

test "readConfigurationFile: empty file" {
    const allocator = std.heap.page_allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_config_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/config/empty.conf" });
    defer allocator.free(absolute_path_to_config_file);

    var configuration = createDefaultConfiguration();

    readConfigurationFile(absolute_path_to_config_file, &configuration);

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
}

test "readConfigurationFile: all configuration values" {
    const allocator = std.heap.page_allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_config_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/config/all_values.conf" });
    defer allocator.free(absolute_path_to_config_file);
    var configuration = createDefaultConfiguration();

    readConfigurationFile(absolute_path_to_config_file, &configuration);

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

test "readConfigurationFile: all configuration values plus whitespace and comments" {
    const allocator = std.heap.page_allocator;
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const absolute_path_to_config_file = try std.fs.path.resolve(allocator, &.{ cwd_path, "unit-test-assets/config/with_comments_and_whitespace.conf" });
    defer allocator.free(absolute_path_to_config_file);
    var configuration = createDefaultConfiguration();

    readConfigurationFile(absolute_path_to_config_file, &configuration);

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
    var configuration = createDefaultConfiguration();

    readConfigurationFile(absolute_path_to_config_file, &configuration);

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

/// Parses a single line from the configuration file and updates the configuration accordingly.
/// Returns true if the line is a valid line (key-value pair, an empty line, comment) and false otherwise.
fn parseLine(line: []u8, cfg_file_path: []const u8, configuration: *InjectorConfiguration) bool {
    var l = line;
    if (std.mem.indexOfScalar(u8, l, '#')) |commentStartIdx| {
        // strip end-of-line comment (might be the whole line if the line starts with #)
        l = l[0..commentStartIdx];
    }
    const trimmed = std.mem.trim(u8, l, " \t\r\n");
    l = std.fmt.allocPrint(alloc.page_allocator, "{s}", .{trimmed}) catch |err| {
        print.printError("error in allocPrint while parsing line from configuration file {s}: {}", .{ cfg_file_path, err });
        return false;
    };
    if (l.len == 0) {
        // ignore empty lines or lines that only contain whitespace
        return true;
    }
    if (std.mem.indexOfScalar(u8, l, '=')) |equalsIdx| {
        const key = std.mem.trim(u8, l[0..equalsIdx], " \t\r\n");
        const trimmedValue = std.mem.trim(u8, l[equalsIdx + 1 ..], " \t\r\n");
        const value = std.fmt.allocPrint(alloc.page_allocator, "{s}", .{trimmedValue}) catch |err| {
            print.printError("error in allocPrint while trimming value from configuration file {s}: {}", .{ cfg_file_path, err });
            return false;
        };
        if (std.mem.eql(u8, key, dotnet_path_key)) {
            configuration.dotnet_auto_instrumentation_agent_path_prefix = value;
            return true;
        } else if (std.mem.eql(u8, key, jvm_path_key)) {
            configuration.jvm_auto_instrumentation_agent_path = value;
            return true;
        } else if (std.mem.eql(u8, key, nodejs_path_key)) {
            configuration.nodejs_auto_instrumentation_agent_path = value;
            return true;
        } else {
            print.printError("ignoring unknown configuration key in {s}: {s}={s}", .{ cfg_file_path, key, value });
            return true;
        }
    } else {
        // ignore malformed lines
        print.printError("cannot parse line in {s}: \"{s}\"", .{ cfg_file_path, line });
        return false;
    }
}

test "parseLine: empty line" {
    var configuration = createDefaultConfiguration();
    const valid = parseLine(
        "",
        "/path/to/configuration",
        &configuration,
    );
    try test_util.expectWithMessage(valid, "parseLine(\"\") is valid");
}

test "parseLine: whitespace only" {
    var configuration = createDefaultConfiguration();
    const valid = parseLine(
        try std.fmt.allocPrint(test_util.test_allocator, "  \t ", .{}),
        "/path/to/configuration",
        &configuration,
    );
    try test_util.expectWithMessage(valid, "parseLine(whitespace) is valid");
}

test "parseLine: full line comment" {
    var configuration = createDefaultConfiguration();
    const valid = parseLine(
        try std.fmt.allocPrint(test_util.test_allocator, "# this is a comment", .{}),
        "/path/to/configuration",
        &configuration,
    );
    try test_util.expectWithMessage(valid, "parseLine(full line comment) is valid");
}

test "parseLine: end of line comment" {
    var configuration = createDefaultConfiguration();
    const valid = parseLine(
        try std.fmt.allocPrint(test_util.test_allocator, "key=value # comment", .{}),
        "/path/to/configuration",
        &configuration,
    );
    try test_util.expectWithMessage(valid, "parseLine(end-of-line comment) is valid");
}

test "parseLine: valid key-value pair for unknown key" {
    var configuration = createDefaultConfiguration();
    const valid = parseLine(
        try std.fmt.allocPrint(test_util.test_allocator, "key=value", .{}),
        "/path/to/configuration",
        &configuration,
    );
    try test_util.expectWithMessage(valid, "parseLine(key-value pair/unknown key) is valid");
}

test "parseLine: valid key-value pair for known key" {
    var configuration = createDefaultConfiguration();
    const valid = parseLine(
        try std.fmt.allocPrint(test_util.test_allocator, "jvm_auto_instrumentation_agent_path=/custom/path/to/jvm/agent", .{}),
        "/path/to/configuration",
        &configuration,
    );
    try test_util.expectWithMessage(valid, "parseLine(key-value pair/known key) is valid");
    try testing.expectEqualStrings(
        "/custom/path/to/jvm/agent",
        configuration.jvm_auto_instrumentation_agent_path,
    );
}

test "parseLine: valid key-value pair for known key with end-of-line comment" {
    var configuration = createDefaultConfiguration();
    const valid = parseLine(
        try std.fmt.allocPrint(test_util.test_allocator, "jvm_auto_instrumentation_agent_path=/custom/path/to/jvm/agent # comment", .{}),
        "/path/to/configuration",
        &configuration,
    );
    try test_util.expectWithMessage(valid, "parseLine(key-value pair/known key/eol comment) is valid");
    try testing.expectEqualStrings(
        "/custom/path/to/jvm/agent",
        configuration.jvm_auto_instrumentation_agent_path,
    );
}

test "parseLine: valid key-value pair with whitespace" {
    var configuration = createDefaultConfiguration();
    const valid = parseLine(
        try std.fmt.allocPrint(test_util.test_allocator, "  jvm_auto_instrumentation_agent_path \t =  /custom/path/to/jvm/agent  ", .{}),
        "/path/to/configuration",
        &configuration,
    );
    try test_util.expectWithMessage(valid, "parseLine(key-value pair/known key/whitespace) is valid");
    try testing.expectEqualStrings(
        "/custom/path/to/jvm/agent",
        configuration.jvm_auto_instrumentation_agent_path,
    );
}

test "parseLine: multiple equals characters" {
    var configuration = createDefaultConfiguration();
    const valid = parseLine(
        try std.fmt.allocPrint(test_util.test_allocator, "jvm_auto_instrumentation_agent_path=/path/with/=/character/===", .{}),
        "/path/to/configuration",
        &configuration,
    );
    try test_util.expectWithMessage(valid, "parseLine(key-value pair/known key/multiple equals) is valid");
    try testing.expectEqualStrings(
        "/path/with/=/character/===",
        configuration.jvm_auto_instrumentation_agent_path,
    );
}

test "parseLine: invalid line (no = character)" {
    var configuration = createDefaultConfiguration();
    const valid = parseLine(
        try std.fmt.allocPrint(test_util.test_allocator, "this line is invalid", .{}),
        "/path/to/configuration",
        &configuration,
    );
    try test_util.expectWithMessage(!valid, "parseLine(invalid line) is invalid");
}

test "parseLine: invalid line (line too long)" {
    var configuration = createDefaultConfiguration();
    const valid = parseLine(
        try std.fmt.allocPrint(test_util.test_allocator, "this line is invalid", .{}),
        "/path/to/configuration",
        &configuration,
    );
    try test_util.expectWithMessage(!valid, "parseLine(invalid line) is invalid");
}

fn readConfigurationFromEnvironment(configuration: *InjectorConfiguration) void {
    if (std.posix.getenv(dotnet_path_env_var)) |value| {
        const trimmed_value = std.mem.trim(u8, value, " \t\r\n");
        const dotnet_value = std.fmt.allocPrint(alloc.page_allocator, "{s}", .{trimmed_value}) catch |err| {
            print.printError("Cannot allocate memory to read the injector configuration from the environment: {}", .{err});
            return;
        };
        configuration.dotnet_auto_instrumentation_agent_path_prefix = dotnet_value;
    }
    if (std.posix.getenv(jvm_path_env_var)) |value| {
        const trimmed_value = std.mem.trim(u8, value, " \t\r\n");
        const jvm_value = std.fmt.allocPrint(alloc.page_allocator, "{s}", .{trimmed_value}) catch |err| {
            print.printError("Cannot allocate memory to read the injector configuration from the environment: {}", .{err});
            return;
        };
        configuration.jvm_auto_instrumentation_agent_path = jvm_value;
    }
    if (std.posix.getenv(nodejs_path_env_var)) |value| {
        const trimmed_value = std.mem.trim(u8, value, " \t\r\n");
        const nodejs_value = std.fmt.allocPrint(alloc.page_allocator, "{s}", .{trimmed_value}) catch |err| {
            print.printError("Cannot allocate memory to read the injector configuration from the environment: {}", .{err});
            return;
        };
        configuration.nodejs_auto_instrumentation_agent_path = nodejs_value;
    }
}
