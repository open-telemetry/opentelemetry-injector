// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const config = @import("config.zig");
const print = @import("print.zig");
const types = @import("types.zig");
const test_util = @import("test_util.zig");

const testing = std.testing;

pub const rubyopt_env_var_name = "RUBYOPT";
pub const ruby_additional_gem_path_env_var_name = "OTEL_RUBY_ADDITIONAL_GEM_PATH";

// Packaging contract: within the libc-specific directory (e.g. <prefix>/glibc) the package must provide a
// stable, version-independent entry file at this relative path (a real file or a symlink to the versioned gem).
// The injector requires this absolute path via `RUBYOPT=-r ...`; the gem then loads the rest of the
// OpenTelemetry gems from OTEL_RUBY_ADDITIONAL_GEM_PATH, which we point at the same directory.
const ruby_entry_file_relative_path = "opentelemetry-auto-instrumentation.rb";

var libc_info: ?types.LibCInfo = null;

pub fn setLibcInfo(info: types.LibCInfo) void {
    libc_info = info;
}

/// Returns the modified value for RUBYOPT, including the `-r <entry file>` flag, based on the original value of
/// RUBYOPT. Returns null if Ruby auto-instrumentation is disabled, unconfigured, the libc flavor is unknown, or the
/// entry file cannot be accessed.
///
/// The caller is responsible for freeing the returned string (unless the result is passed on to setenv and needs to
/// stay in memory).
pub fn checkRubyAutoInstrumentationAgentAndGetModifiedRubyoptValue(
    gpa: std.mem.Allocator,
    original_value_optional: ?[:0]const u8,
    configuration: config.InjectorConfiguration,
) ?[:0]u8 {
    const libc_dir = determineLibcDir(gpa, configuration) orelse return null;
    defer gpa.free(libc_dir);

    const entry_file = std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ libc_dir, ruby_entry_file_relative_path }, 0) catch |err| {
        print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ rubyopt_env_var_name, err });
        return null;
    };
    defer gpa.free(entry_file);

    // Stand down if the entry file does not exist; requiring a missing file would crash the Ruby process at startup.
    std.fs.cwd().access(entry_file, .{}) catch |err| {
        print.printError("Skipping the injection of the Ruby OpenTelemetry auto-instrumentation in \"{s}\" because of an issue accessing the entry point at \"{s}\": {}", .{ rubyopt_env_var_name, entry_file, err });
        return null;
    };

    const require_flag = std.fmt.allocPrintSentinel(gpa, "-r {s}", .{entry_file}, 0) catch |err| {
        print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ rubyopt_env_var_name, err });
        return null;
    };

    return getModifiedRubyoptValue(gpa, original_value_optional, require_flag);
}

/// Returns the value for OTEL_RUBY_ADDITIONAL_GEM_PATH (the libc-specific gem directory) so the auto-instrumentation
/// gem can locate its bundled OpenTelemetry dependencies. Returns null under the same conditions as
/// checkRubyAutoInstrumentationAgentAndGetModifiedRubyoptValue.
///
/// The caller is responsible for freeing the returned string (unless it is passed on to setenv).
pub fn getRubyAdditionalGemPath(
    gpa: std.mem.Allocator,
    configuration: config.InjectorConfiguration,
) ?[:0]u8 {
    return determineLibcDir(gpa, configuration);
}

/// Resolves <prefix>/<libc flavor> and returns it, or null if disabled, unconfigured, or the libc flavor is unknown.
fn determineLibcDir(gpa: std.mem.Allocator, configuration: config.InjectorConfiguration) ?[:0]u8 {
    if (configuration.ruby_instrumentation_disabled or configuration.ruby_auto_instrumentation_agent_path_prefix.len == 0) {
        print.printInfo("Skipping the injection of the Ruby OpenTelemetry auto-instrumentation because it has been explicitly disabled.", .{});
        return null;
    }

    if (libc_info == null) {
        print.printError("invariant violated: libc info has not been set prior to calling determineLibcDir().", .{});
        return null;
    }
    if (libc_info.?.flavor == .UNKNOWN) {
        print.printError("Cannot determine libc flavor", .{});
        return null;
    }

    const libc_flavor_suffix = switch (libc_info.?.flavor) {
        .GNU => "glibc",
        .MUSL => "musl",
        else => unreachable,
    };

    return std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{
        configuration.ruby_auto_instrumentation_agent_path_prefix, libc_flavor_suffix,
    }, 0) catch |err| {
        print.printError("Cannot allocate memory to manipulate the value of \"{s}\" for libc flavor \"{s}\": {}", .{
            rubyopt_env_var_name, libc_flavor_suffix, err,
        });
        return null;
    };
}

fn getModifiedRubyoptValue(
    gpa: std.mem.Allocator,
    original_value_optional: ?[:0]const u8,
    require_flag: [:0]u8,
) ?[:0]u8 {
    if (original_value_optional) |original_value| {
        if (std.mem.indexOf(u8, original_value, require_flag)) |_| {
            // Our `-r ...` flag is already present in RUBYOPT, do nothing. This avoids double injection, e.g. when we
            // inject into a shell entry point that then starts the Ruby process, which inherits the modified env.
            gpa.free(require_flag);
            return null;
        }

        // RUBYOPT is already set, prepend our `-r ...` flag to the original value.
        defer gpa.free(require_flag);
        return std.fmt.allocPrintSentinel(gpa, "{s} {s}", .{ require_flag, original_value }, 0) catch |err| {
            print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ rubyopt_env_var_name, err });
            return null;
        };
    }

    // RUBYOPT is not set, simply return the `-r ...` flag.
    return require_flag[0..];
}

test "checkRubyAutoInstrumentationAgentAndGetModifiedRubyoptValue: returns null if ruby instrumentation is disabled" {
    const allocator = testing.allocator;
    _resetState();
    defer _resetState();

    libc_info = test_util.testLibcInfo(.GNU);
    const configuration = testConfiguration("/some/valid/path", true);
    const result = checkRubyAutoInstrumentationAgentAndGetModifiedRubyoptValue(allocator, null, configuration);
    try test_util.expectWithMessage(result == null, "result == null");
}

test "checkRubyAutoInstrumentationAgentAndGetModifiedRubyoptValue: returns null if path prefix is empty" {
    const allocator = testing.allocator;
    _resetState();
    defer _resetState();

    libc_info = test_util.testLibcInfo(.GNU);
    const configuration = testConfiguration("", false);
    const result = checkRubyAutoInstrumentationAgentAndGetModifiedRubyoptValue(allocator, null, configuration);
    try test_util.expectWithMessage(result == null, "result == null");
}

test "checkRubyAutoInstrumentationAgentAndGetModifiedRubyoptValue: returns null if libc flavor is unknown" {
    const allocator = testing.allocator;
    _resetState();
    defer _resetState();

    libc_info = test_util.testLibcInfo(.UNKNOWN);
    const configuration = testConfiguration("/some/valid/path", false);
    const result = checkRubyAutoInstrumentationAgentAndGetModifiedRubyoptValue(allocator, null, configuration);
    try test_util.expectWithMessage(result == null, "result == null");
}

test "checkRubyAutoInstrumentationAgentAndGetModifiedRubyoptValue: returns null if entry file cannot be accessed" {
    const allocator = testing.allocator;
    _resetState();
    defer _resetState();

    libc_info = test_util.testLibcInfo(.GNU);
    const configuration = testConfiguration("/invalid/path", false);
    const result = checkRubyAutoInstrumentationAgentAndGetModifiedRubyoptValue(allocator, null, configuration);
    try test_util.expectWithMessage(result == null, "result == null");
}

test "getRubyAdditionalGemPath: returns <prefix>/glibc for GNU libc" {
    const allocator = testing.allocator;
    _resetState();
    defer _resetState();

    libc_info = test_util.testLibcInfo(.GNU);
    const configuration = testConfiguration("/usr/lib/opentelemetry/ruby", false);
    const result = getRubyAdditionalGemPath(allocator, configuration);
    defer if (result) |v| allocator.free(v);
    try testing.expectEqualStrings("/usr/lib/opentelemetry/ruby/glibc", result orelse "-");
}

test "getRubyAdditionalGemPath: returns <prefix>/musl for musl libc" {
    const allocator = testing.allocator;
    _resetState();
    defer _resetState();

    libc_info = test_util.testLibcInfo(.MUSL);
    const configuration = testConfiguration("/usr/lib/opentelemetry/ruby", false);
    const result = getRubyAdditionalGemPath(allocator, configuration);
    defer if (result) |v| allocator.free(v);
    try testing.expectEqualStrings("/usr/lib/opentelemetry/ruby/musl", result orelse "-");
}

test "getModifiedRubyoptValue: returns -r flag if original value is unset" {
    const allocator = testing.allocator;
    const require_flag = try std.fmt.allocPrintSentinel(allocator, "-r /usr/lib/opentelemetry/ruby/glibc/opentelemetry-auto-instrumentation.rb", .{}, 0);
    const result = getModifiedRubyoptValue(allocator, null, require_flag);
    defer if (result) |v| allocator.free(v);
    try testing.expectEqualStrings(
        "-r /usr/lib/opentelemetry/ruby/glibc/opentelemetry-auto-instrumentation.rb",
        result orelse "-",
    );
}

test "getModifiedRubyoptValue: prepends -r flag if original value exists" {
    const allocator = testing.allocator;
    const original_value: [:0]const u8 = "--enable-frozen-string-literal"[0.. :0];
    const require_flag = try std.fmt.allocPrintSentinel(allocator, "-r /opt/otel/ruby/glibc/opentelemetry-auto-instrumentation.rb", .{}, 0);
    const result = getModifiedRubyoptValue(allocator, original_value, require_flag);
    defer if (result) |v| allocator.free(v);
    try testing.expectEqualStrings(
        "-r /opt/otel/ruby/glibc/opentelemetry-auto-instrumentation.rb --enable-frozen-string-literal",
        result orelse "-",
    );
}

test "getModifiedRubyoptValue: does nothing if our -r flag is already present" {
    const allocator = testing.allocator;
    const original_value: [:0]const u8 = "--yjit -r /opt/otel/ruby/glibc/opentelemetry-auto-instrumentation.rb --enable-frozen-string-literal"[0.. :0];
    const require_flag = try std.fmt.allocPrintSentinel(allocator, "-r /opt/otel/ruby/glibc/opentelemetry-auto-instrumentation.rb", .{}, 0);
    const result = getModifiedRubyoptValue(allocator, original_value, require_flag);
    try test_util.expectWithMessage(result == null, "result == null");
}

/// Builds a minimal InjectorConfiguration for unit tests. Only the Ruby-relevant fields are meaningful.
fn testConfiguration(path_prefix: []const u8, disabled: bool) config.InjectorConfiguration {
    return config.InjectorConfiguration{
        .dotnet_auto_instrumentation_agent_path_prefix = @constCast(""),
        .jvm_auto_instrumentation_agent_path = @constCast(""),
        .nodejs_auto_instrumentation_agent_path = @constCast(""),
        .python_auto_instrumentation_agent_path_prefix = @constCast(""),
        .ruby_auto_instrumentation_agent_path_prefix = @constCast(path_prefix),
        .all_auto_instrumentation_agents_env_path = @constCast(""),
        .all_auto_instrumentation_agents_env_vars = std.StringHashMap([]u8).init(testing.allocator),
        .include_paths = &.{},
        .exclude_paths = &.{},
        .include_args = &.{},
        .exclude_args = &.{},
        .dotnet_instrumentation_disabled = false,
        .jvm_instrumentation_disabled = false,
        .nodejs_instrumentation_disabled = false,
        .python_instrumentation_disabled = false,
        .ruby_instrumentation_disabled = disabled,
    };
}

/// Only used for unit tests.
fn _resetState() void {
    libc_info = null;
}
