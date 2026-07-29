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

    return getModifiedRubyoptValue(gpa, original_value_optional, require_flag, entry_file);
}

/// Returns the value for OTEL_RUBY_ADDITIONAL_GEM_PATH (the libc-specific gem directory) so the auto-instrumentation
/// gem can locate its bundled OpenTelemetry dependencies. Returns null under the same conditions as
/// checkRubyAutoInstrumentationAgentAndGetModifiedRubyoptValue -- in particular, the entry file must exist. The
/// two env vars share a gate so we never inject one without the other.
///
/// The caller is responsible for freeing the returned string (unless it is passed on to setenv).
pub fn getRubyAdditionalGemPath(
    gpa: std.mem.Allocator,
    configuration: config.InjectorConfiguration,
) ?[:0]u8 {
    const libc_dir = determineLibcDir(gpa, configuration) orelse return null;

    const entry_file = std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ libc_dir, ruby_entry_file_relative_path }, 0) catch |err| {
        print.printError("Cannot allocate memory to manipulate the value of \"{s}\": {}", .{ ruby_additional_gem_path_env_var_name, err });
        gpa.free(libc_dir);
        return null;
    };
    defer gpa.free(entry_file);

    std.fs.cwd().access(entry_file, .{}) catch |err| {
        print.printError("Skipping the injection of the Ruby OpenTelemetry auto-instrumentation in \"{s}\" because of an issue accessing the entry point at \"{s}\": {}", .{ ruby_additional_gem_path_env_var_name, entry_file, err });
        gpa.free(libc_dir);
        return null;
    };

    return libc_dir;
}

/// Resolves <prefix>/<libc flavor> and returns it, or null if disabled, unconfigured, the prefix
/// contains whitespace, or the libc flavor is unknown.
fn determineLibcDir(gpa: std.mem.Allocator, configuration: config.InjectorConfiguration) ?[:0]u8 {
    if (configuration.ruby_instrumentation_disabled) {
        print.printInfo("Skipping the injection of the Ruby OpenTelemetry auto-instrumentation because it has been explicitly disabled.", .{});
        return null;
    }
    if (configuration.ruby_auto_instrumentation_agent_path_prefix.len == 0) {
        // The default state on hosts that have the injector but no ruby.conf drop-in. This runs for every
        // process on the host, so keep the log at debug to avoid flooding operator logs with an intentional
        // no-op.
        print.printDebug("Skipping the injection of the Ruby OpenTelemetry auto-instrumentation because it has not been configured (no path prefix set).", .{});
        return null;
    }

    // Ruby tokenizes RUBYOPT on whitespace like a command line, so a prefix containing whitespace would
    // either crash every Ruby process with "invalid switch in RUBYOPT" (benign misconfig) or, worse, let
    // an attacker inject additional Ruby switches such as `-I<dir>` to hijack $LOAD_PATH (security). Reject
    // whitespace at composition time and stand down.
    for (configuration.ruby_auto_instrumentation_agent_path_prefix) |c| {
        if (std.ascii.isWhitespace(c)) {
            print.printError("Skipping the injection of the Ruby OpenTelemetry auto-instrumentation because the configured path prefix \"{s}\" contains a whitespace character; whitespace in the prefix would break Ruby's RUBYOPT tokenization.", .{configuration.ruby_auto_instrumentation_agent_path_prefix});
            return null;
        }
    }

    if (libc_info == null) {
        print.printError("invariant violated: libc info has not been set prior to calling determineLibcDir().", .{});
        return null;
    }

    // Fail-safe on any libc flavor we don't have a directory suffix for. This covers .UNKNOWN today, and
    // any variant added to LibCFlavor in the future -- an `else => unreachable` here would panic in every
    // process's .init_array on hosts running a newly-supported libc before ruby.zig learns about it.
    const libc_flavor_suffix = switch (libc_info.?.flavor) {
        .GNU => "glibc",
        .MUSL => "musl",
        else => {
            print.printError("Cannot determine libc flavor for Ruby auto-instrumentation: \"{s}\"", .{@tagName(libc_info.?.flavor)});
            return null;
        },
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
    entry_file: []const u8,
) ?[:0]u8 {
    if (original_value_optional) |original_value| {
        if (rubyoptAlreadyRequires(original_value, entry_file)) {
            // Our entry file is already required in RUBYOPT, do nothing. This avoids double injection, e.g. when we
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

/// Returns true when `rubyopt_value` already requires `entry_file` via `-r`. Mirrors Ruby's RUBYOPT
/// parsing: whitespace-tokenized, and each `-r` token can be followed by the path as the next token
/// (`-r PATH`) or attached to the flag (`-rPATH`). Substring matching is not enough -- a coincidental
/// `-r <entry_file>.disabled` would falsely suppress our injection, and Ruby's no-space attached form
/// would slip past a `"-r " ++ path` substring check and cause double injection.
fn rubyoptAlreadyRequires(rubyopt_value: []const u8, entry_file: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, rubyopt_value, " \t\r\n");
    while (tokens.next()) |token| {
        if (std.mem.eql(u8, token, "-r")) {
            if (tokens.next()) |next_token| {
                if (std.mem.eql(u8, next_token, entry_file)) return true;
            }
        } else if (std.mem.startsWith(u8, token, "-r") and std.mem.eql(u8, token[2..], entry_file)) {
            return true;
        }
    }
    return false;
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

test "checkRubyAutoInstrumentationAgentAndGetModifiedRubyoptValue: returns null if prefix contains whitespace" {
    const allocator = testing.allocator;
    _resetState();
    defer _resetState();

    libc_info = test_util.testLibcInfo(.GNU);
    // Rejected because a space in the prefix would let Ruby's RUBYOPT tokenizer parse additional switches.
    const configuration_space = testConfiguration("/opt/OpenTelemetry Injector/ruby", false);
    try test_util.expectWithMessage(
        checkRubyAutoInstrumentationAgentAndGetModifiedRubyoptValue(allocator, null, configuration_space) == null,
        "space in prefix -> null",
    );
    // Tab, newline, and carriage return also break RUBYOPT tokenization.
    const configuration_tab = testConfiguration("/opt/otel\tinjector/ruby", false);
    try test_util.expectWithMessage(
        checkRubyAutoInstrumentationAgentAndGetModifiedRubyoptValue(allocator, null, configuration_tab) == null,
        "tab in prefix -> null",
    );
    const configuration_newline = testConfiguration("/opt/otel\ninjector/ruby", false);
    try test_util.expectWithMessage(
        checkRubyAutoInstrumentationAgentAndGetModifiedRubyoptValue(allocator, null, configuration_newline) == null,
        "newline in prefix -> null",
    );
    const configuration_cr = testConfiguration("/opt/otel\rinjector/ruby", false);
    try test_util.expectWithMessage(
        checkRubyAutoInstrumentationAgentAndGetModifiedRubyoptValue(allocator, null, configuration_cr) == null,
        "cr in prefix -> null",
    );
    // Vertical tab and form feed round out ASCII whitespace.
    const configuration_vt = testConfiguration("/opt/otel\x0binjector/ruby", false);
    try test_util.expectWithMessage(
        checkRubyAutoInstrumentationAgentAndGetModifiedRubyoptValue(allocator, null, configuration_vt) == null,
        "vertical tab in prefix -> null",
    );
    const configuration_ff = testConfiguration("/opt/otel\x0cinjector/ruby", false);
    try test_util.expectWithMessage(
        checkRubyAutoInstrumentationAgentAndGetModifiedRubyoptValue(allocator, null, configuration_ff) == null,
        "form feed in prefix -> null",
    );
}

test "getRubyAdditionalGemPath: returns <prefix>/glibc for GNU libc" {
    const allocator = testing.allocator;
    _resetState();
    defer _resetState();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makeDir("glibc");
    (try tmp_dir.dir.createFile("glibc/" ++ ruby_entry_file_relative_path, .{})).close();
    const prefix = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(prefix);

    libc_info = test_util.testLibcInfo(.GNU);
    const configuration = testConfiguration(prefix, false);
    const result = getRubyAdditionalGemPath(allocator, configuration);
    defer if (result) |v| allocator.free(v);
    const expected = try std.fmt.allocPrint(allocator, "{s}/glibc", .{prefix});
    defer allocator.free(expected);
    try testing.expectEqualStrings(expected, result orelse "-");
}

test "getRubyAdditionalGemPath: returns <prefix>/musl for musl libc" {
    const allocator = testing.allocator;
    _resetState();
    defer _resetState();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makeDir("musl");
    (try tmp_dir.dir.createFile("musl/" ++ ruby_entry_file_relative_path, .{})).close();
    const prefix = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(prefix);

    libc_info = test_util.testLibcInfo(.MUSL);
    const configuration = testConfiguration(prefix, false);
    const result = getRubyAdditionalGemPath(allocator, configuration);
    defer if (result) |v| allocator.free(v);
    const expected = try std.fmt.allocPrint(allocator, "{s}/musl", .{prefix});
    defer allocator.free(expected);
    try testing.expectEqualStrings(expected, result orelse "-");
}

test "getRubyAdditionalGemPath: returns null if entry file cannot be accessed" {
    const allocator = testing.allocator;
    _resetState();
    defer _resetState();

    libc_info = test_util.testLibcInfo(.GNU);
    const configuration = testConfiguration("/invalid/path", false);
    const result = getRubyAdditionalGemPath(allocator, configuration);
    try test_util.expectWithMessage(result == null, "result == null");
}

test "getModifiedRubyoptValue: returns -r flag if original value is unset" {
    const allocator = testing.allocator;
    const entry_file = "/usr/lib/opentelemetry/ruby/glibc/opentelemetry-auto-instrumentation.rb";
    const require_flag = try std.fmt.allocPrintSentinel(allocator, "-r {s}", .{entry_file}, 0);
    const result = getModifiedRubyoptValue(allocator, null, require_flag, entry_file);
    defer if (result) |v| allocator.free(v);
    try testing.expectEqualStrings(
        "-r /usr/lib/opentelemetry/ruby/glibc/opentelemetry-auto-instrumentation.rb",
        result orelse "-",
    );
}

test "getModifiedRubyoptValue: prepends -r flag if original value exists" {
    const allocator = testing.allocator;
    const original_value: [:0]const u8 = "--enable-frozen-string-literal"[0.. :0];
    const entry_file = "/opt/otel/ruby/glibc/opentelemetry-auto-instrumentation.rb";
    const require_flag = try std.fmt.allocPrintSentinel(allocator, "-r {s}", .{entry_file}, 0);
    const result = getModifiedRubyoptValue(allocator, original_value, require_flag, entry_file);
    defer if (result) |v| allocator.free(v);
    try testing.expectEqualStrings(
        "-r /opt/otel/ruby/glibc/opentelemetry-auto-instrumentation.rb --enable-frozen-string-literal",
        result orelse "-",
    );
}

test "getModifiedRubyoptValue: does nothing if our -r flag is already present (space form)" {
    const allocator = testing.allocator;
    const original_value: [:0]const u8 = "--yjit -r /opt/otel/ruby/glibc/opentelemetry-auto-instrumentation.rb --enable-frozen-string-literal"[0.. :0];
    const entry_file = "/opt/otel/ruby/glibc/opentelemetry-auto-instrumentation.rb";
    const require_flag = try std.fmt.allocPrintSentinel(allocator, "-r {s}", .{entry_file}, 0);
    const result = getModifiedRubyoptValue(allocator, original_value, require_flag, entry_file);
    try test_util.expectWithMessage(result == null, "result == null");
}

test "getModifiedRubyoptValue: does nothing if our -r flag is already present (attached -rPATH form)" {
    const allocator = testing.allocator;
    // Ruby accepts `-rPATH` (no space between flag and path) as an equivalent to `-r PATH`.
    const original_value: [:0]const u8 = "--yjit -r/opt/otel/ruby/glibc/opentelemetry-auto-instrumentation.rb --enable-frozen-string-literal"[0.. :0];
    const entry_file = "/opt/otel/ruby/glibc/opentelemetry-auto-instrumentation.rb";
    const require_flag = try std.fmt.allocPrintSentinel(allocator, "-r {s}", .{entry_file}, 0);
    const result = getModifiedRubyoptValue(allocator, original_value, require_flag, entry_file);
    try test_util.expectWithMessage(result == null, "result == null");
}

test "getModifiedRubyoptValue: prepends when RUBYOPT contains our path as a substring of a different token" {
    const allocator = testing.allocator;
    // A coincidental `-r <entry_file>.disabled` must not suppress our injection.
    const entry_file = "/opt/otel/ruby/glibc/opentelemetry-auto-instrumentation.rb";
    const original_value: [:0]const u8 = "-r /opt/otel/ruby/glibc/opentelemetry-auto-instrumentation.rb.disabled"[0.. :0];
    const require_flag = try std.fmt.allocPrintSentinel(allocator, "-r {s}", .{entry_file}, 0);
    const result = getModifiedRubyoptValue(allocator, original_value, require_flag, entry_file);
    defer if (result) |v| allocator.free(v);
    try testing.expectEqualStrings(
        "-r /opt/otel/ruby/glibc/opentelemetry-auto-instrumentation.rb -r /opt/otel/ruby/glibc/opentelemetry-auto-instrumentation.rb.disabled",
        result orelse "-",
    );
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
        .dotnet_auto_instrumentation_minimum_dotnet_major_version = config.default_dotnet_auto_instrumentation_minimum_dotnet_major_version,
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
